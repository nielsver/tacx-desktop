"""Interval preset engine — swaps ERG targets on a timer."""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Awaitable, Callable, Optional


class IntervalPhase(Enum):
    IDLE = auto()
    WORK = auto()
    REST = auto()
    DONE = auto()


@dataclass(frozen=True)
class IntervalPreset:
    key: str
    label: str
    repeats: int
    work_s: int
    rest_s: int
    work_watts: int
    rest_watts: int
    description: str = ""

    @property
    def total_segments(self) -> int:
        # work + rest per repeat (last rest still counted for simplicity)
        return self.repeats * 2


PRESETS: list[IntervalPreset] = [
    IntervalPreset(
        key="10x30_30",
        label="10×30/30s",
        repeats=10,
        work_s=30,
        rest_s=30,
        work_watts=280,
        rest_watts=120,
        description="Classic VO2 bursts — 10×30s work / 30s recovery",
    ),
    IntervalPreset(
        key="5x3_2",
        label="5×3/2min",
        repeats=5,
        work_s=180,
        rest_s=120,
        work_watts=250,
        rest_watts=140,
        description="Sweet-spot / threshold blocks — 5×3min / 2min",
    ),
    IntervalPreset(
        key="4x4_3",
        label="4×4/3min",
        repeats=4,
        work_s=240,
        rest_s=180,
        work_watts=270,
        rest_watts=130,
        description="Norwegian 4×4 — 4×4min / 3min",
    ),
]


def preset_by_key(key: str) -> Optional[IntervalPreset]:
    for p in PRESETS:
        if p.key == key:
            return p
    return None


OnTick = Callable[["IntervalEngine"], None]
OnTarget = Callable[[int], Awaitable[None]]


@dataclass
class IntervalEngine:
    """Runs a preset: WORK → REST × N, calling on_target with ERG watts."""

    on_tick: Optional[OnTick] = field(default=None, repr=False)
    on_target: Optional[OnTarget] = field(default=None, repr=False)

    preset: Optional[IntervalPreset] = None
    phase: IntervalPhase = IntervalPhase.IDLE
    repeat_index: int = 0  # 0-based current interval (work+rest pair)
    phase_remaining_s: float = 0.0
    running: bool = False
    _task: Optional[asyncio.Task] = field(default=None, repr=False)
    _phase_started: float = field(default=0.0, repr=False)
    _phase_duration: float = field(default=0.0, repr=False)

    @property
    def status_text(self) -> str:
        if self.phase == IntervalPhase.IDLE:
            return "Idle"
        if self.phase == IntervalPhase.DONE:
            return "Done"
        p = self.preset
        if not p:
            return "—"
        n = self.repeat_index + 1
        rem = max(0, int(round(self.phase_remaining_s)))
        mm, ss = divmod(rem, 60)
        phase = "WORK" if self.phase == IntervalPhase.WORK else "REST"
        return f"{p.label} · {phase} {n}/{p.repeats} · {mm:02d}:{ss:02d}"

    async def start(self, preset: IntervalPreset) -> None:
        await self.stop()
        self.preset = preset
        self.running = True
        self.repeat_index = 0
        self.phase = IntervalPhase.WORK
        await self._enter_phase(IntervalPhase.WORK, preset.work_s, preset.work_watts)
        self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        self.running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        self.phase = IntervalPhase.IDLE
        self.phase_remaining_s = 0.0
        if self.on_tick:
            self.on_tick(self)

    async def _enter_phase(self, phase: IntervalPhase, duration_s: int, watts: int) -> None:
        self.phase = phase
        self._phase_duration = float(duration_s)
        self._phase_started = time.monotonic()
        self.phase_remaining_s = float(duration_s)
        if self.on_target:
            await self.on_target(watts)
        if self.on_tick:
            self.on_tick(self)

    async def _run(self) -> None:
        assert self.preset is not None
        preset = self.preset
        try:
            while self.running:
                await asyncio.sleep(0.2)
                elapsed = time.monotonic() - self._phase_started
                self.phase_remaining_s = max(0.0, self._phase_duration - elapsed)
                if self.on_tick:
                    self.on_tick(self)
                if self.phase_remaining_s > 0:
                    continue

                if self.phase == IntervalPhase.WORK:
                    await self._enter_phase(
                        IntervalPhase.REST, preset.rest_s, preset.rest_watts
                    )
                elif self.phase == IntervalPhase.REST:
                    self.repeat_index += 1
                    if self.repeat_index >= preset.repeats:
                        self.phase = IntervalPhase.DONE
                        self.running = False
                        self.phase_remaining_s = 0.0
                        if self.on_tick:
                            self.on_tick(self)
                        break
                    await self._enter_phase(
                        IntervalPhase.WORK, preset.work_s, preset.work_watts
                    )
        except asyncio.CancelledError:
            raise
