"""Unit tests for FTMS Indoor Bike Data parsing and interval engine."""

from __future__ import annotations

import asyncio
import struct

import pytest

from tacx_desktop.ble_ftms import parse_indoor_bike_data, parse_power_range, parse_resistance_range
from tacx_desktop.interval_timer import PRESETS, IntervalEngine, IntervalPhase


def test_parse_speed_cadence_power():
    # flags: cadence (bit2) + power (bit6); more_data=0 so speed present
    flags = 0x0004 | 0x0040
    # speed 30.00 km/h => 3000; cadence 90.0 rpm => 180; power 200 W
    payload = struct.pack("<HHHh", flags, 3000, 180, 200)
    parsed = parse_indoor_bike_data(payload)
    assert parsed["speed_kmh"] == pytest.approx(30.0)
    assert parsed["cadence_rpm"] == pytest.approx(90.0)
    assert parsed["power_w"] == pytest.approx(200.0)


def test_parse_power_only_more_data():
    # more_data=1, no speed; power bit set
    flags = 0x0001 | 0x0040
    payload = struct.pack("<Hh", flags, 185)
    parsed = parse_indoor_bike_data(payload)
    assert "speed_kmh" not in parsed
    assert parsed["power_w"] == 185


def test_resistance_range_percent():
    # min=0, max=1000, step=10 (raw * 0.1 units)
    raw = struct.pack("<hhh", 0, 1000, 10)
    rr = parse_resistance_range(raw)
    assert rr.min_pct == 0.0
    assert rr.max_pct == 100.0
    assert rr.step_pct == pytest.approx(1.0)


def test_power_range():
    raw = struct.pack("<hhh", 0, 800, 1)
    pr = parse_power_range(raw)
    assert pr.min_w == 0
    assert pr.max_w == 800
    assert pr.step_w == 1


@pytest.mark.asyncio
async def test_interval_engine_swaps_targets():
    targets: list[int] = []

    async def on_target(w: int) -> None:
        targets.append(w)

    engine = IntervalEngine(on_target=on_target)
    # Tiny preset: 1 repeat, 0.4s work / 0.4s rest
    from tacx_desktop.interval_timer import IntervalPreset

    tiny = IntervalPreset(
        key="tiny",
        label="tiny",
        repeats=1,
        work_s=1,
        rest_s=1,
        work_watts=300,
        rest_watts=100,
    )
    await engine.start(tiny)
    assert engine.phase == IntervalPhase.WORK
    assert targets[0] == 300
    await asyncio.sleep(1.2)
    assert 100 in targets
    # wait for completion
    await asyncio.sleep(1.2)
    assert engine.phase == IntervalPhase.DONE
    await engine.stop()


def test_presets_defined():
    keys = {p.key for p in PRESETS}
    assert "10x30_30" in keys
    assert "5x3_2" in keys
    assert "4x4_3" in keys
