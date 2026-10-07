"""Demo stub backend — no BLE hardware required."""

from __future__ import annotations

import asyncio
import math
import random
import time
from typing import Optional

from tacx_desktop.backend import (
    ConnectionState,
    ControlMode,
    DiscoveredDevice,
    PowerRange,
    ResistanceRange,
    TrainerBackend,
    TrainerMetrics,
)


class DemoStub(TrainerBackend):
    """Simulates an FTMS indoor bike for UI / interval / ERG smoke tests."""

    def __init__(self) -> None:
        super().__init__(is_demo=True)
        self._state = ConnectionState.DISCONNECTED
        self._mode = ControlMode.IDLE
        self._metrics = TrainerMetrics()
        self._resistance_range = ResistanceRange(min_pct=0.0, max_pct=100.0, step_pct=1.0)
        self._power_range = PowerRange(min_w=0, max_w=1000, step_w=1)
        self._target_power = 150
        self._resistance_pct = 20.0
        self._task: Optional[asyncio.Task] = None
        self._t0 = time.monotonic()
        self._connected_name = "DEMO Tacx Neo (stub)"

    def get_metrics(self) -> TrainerMetrics:
        return self._metrics

    def get_state(self) -> ConnectionState:
        return self._state

    def get_mode(self) -> ControlMode:
        return self._mode

    def get_resistance_range(self) -> ResistanceRange:
        return self._resistance_range

    def get_power_range(self) -> PowerRange:
        return self._power_range

    def _set_state(self, state: ConnectionState, detail: str = "") -> None:
        self._state = state
        self._emit_state(state, detail)

    async def scan(self, timeout_s: float = 8.0) -> list[DiscoveredDevice]:
        self._set_state(ConnectionState.SCANNING, "DEMO scan…")
        await asyncio.sleep(min(0.4, timeout_s))
        devices = [
            DiscoveredDevice(address="DEMO:00:11:22:33:44:55", name=self._connected_name, rssi=-42),
            DiscoveredDevice(address="DEMO:AA:BB:CC:DD:EE:FF", name="DEMO Flux 2 (stub)", rssi=-55),
        ]
        self._set_state(ConnectionState.DISCONNECTED, f"Found {len(devices)} demo device(s)")
        return devices

    async def connect(self, address: Optional[str] = None) -> None:
        self._set_state(ConnectionState.CONNECTING, "DEMO connecting…")
        await asyncio.sleep(0.3)
        await self.request_control()
        self._t0 = time.monotonic()
        self._task = asyncio.create_task(self._tick_loop())
        self._set_state(ConnectionState.CONNECTED, address or self._connected_name)

    async def disconnect(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        self._mode = ControlMode.IDLE
        self._metrics = TrainerMetrics()
        self._set_state(ConnectionState.DISCONNECTED, "DEMO disconnected")

    async def request_control(self) -> None:
        await asyncio.sleep(0.05)

    async def set_target_power(self, watts: int) -> None:
        pr = self._power_range
        watts = max(pr.min_w, min(pr.max_w, int(watts)))
        self._target_power = watts
        self._mode = ControlMode.ERG
        self._metrics.target_power_w = float(watts)
        self._metrics.resistance_pct = None
        self._emit_metrics(self._metrics)

    async def set_resistance(self, percent: float) -> None:
        rr = self._resistance_range
        percent = max(rr.min_pct, min(rr.max_pct, float(percent)))
        self._resistance_pct = percent
        self._mode = ControlMode.RESISTANCE
        self._metrics.resistance_pct = percent
        self._metrics.target_power_w = None
        self._emit_metrics(self._metrics)

    async def _tick_loop(self) -> None:
        try:
            while True:
                self._simulate_tick()
                await asyncio.sleep(0.25)
        except asyncio.CancelledError:
            raise

    def _simulate_tick(self) -> None:
        t = time.monotonic() - self._t0
        wobble = math.sin(t * 1.7) * 8.0 + random.uniform(-3, 3)
        if self._mode == ControlMode.ERG:
            target = self._target_power
            # Approach target with lag + noise
            current = self._metrics.power_w
            power = current + (target - current) * 0.35 + wobble * 0.4
            cadence = 85 + math.sin(t * 0.9) * 4 + random.uniform(-1, 1)
            speed = 28 + (power / 250.0) * 6 + math.sin(t * 0.5) * 0.8
            self._metrics.target_power_w = float(target)
            self._metrics.resistance_pct = None
        elif self._mode == ControlMode.RESISTANCE:
            # Rough mapping: resistance % drives expected power at ~90 rpm
            expected = 50 + self._resistance_pct * 4.5
            current = self._metrics.power_w
            power = current + (expected - current) * 0.25 + wobble
            cadence = 80 + math.sin(t * 0.7) * 5
            speed = 22 + (100 - self._resistance_pct) * 0.12
            self._metrics.resistance_pct = self._resistance_pct
            self._metrics.target_power_w = None
        else:
            power = max(0.0, 40 + wobble)
            cadence = 60 + math.sin(t) * 3
            speed = 18 + math.sin(t * 0.4) * 1.5

        self._metrics.power_w = max(0.0, power)
        self._metrics.cadence_rpm = max(0.0, cadence)
        self._metrics.speed_kmh = max(0.0, speed)
        self._emit_metrics(self._metrics)
