"""Demo backend smoke tests (no BLE)."""

from __future__ import annotations

import asyncio

import pytest

from tacx_desktop.backend import ConnectionState, ControlMode
from tacx_desktop.demo_backend import DemoStub


@pytest.mark.asyncio
async def test_demo_scan_connect_erg_resistance():
    b = DemoStub()
    assert b.is_demo
    devices = await b.scan(0.2)
    assert len(devices) >= 1
    await b.connect(devices[0].address)
    assert b.get_state() == ConnectionState.CONNECTED

    await b.set_target_power(220)
    assert b.get_mode() == ControlMode.ERG
    await asyncio.sleep(0.6)
    m = b.get_metrics()
    assert m.target_power_w == 220
    assert m.power_w > 50

    await b.set_resistance(55)
    assert b.get_mode() == ControlMode.RESISTANCE
    assert b.get_metrics().resistance_pct == 55.0

    await b.disconnect()
    assert b.get_state() == ConnectionState.DISCONNECTED
