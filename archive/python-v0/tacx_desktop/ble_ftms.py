"""Real FTMS Indoor Bike backend over Bleak (WinRT on Windows)."""

from __future__ import annotations

import asyncio
import logging
import struct
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

log = logging.getLogger(__name__)

# GATT UUIDs (16-bit Bluetooth SIG)
FTMS_SERVICE = "00001826-0000-1000-8000-00805f9b34fb"
INDOOR_BIKE_DATA = "00002ad2-0000-1000-8000-00805f9b34fb"
CONTROL_POINT = "00002ad9-0000-1000-8000-00805f9b34fb"
SUPPORTED_RESISTANCE_RANGE = "00002ad6-0000-1000-8000-00805f9b34fb"
SUPPORTED_POWER_RANGE = "00002ad8-0000-1000-8000-00805f9b34fb"
MACHINE_STATUS = "00002ada-0000-1000-8000-00805f9b34fb"

# Control Point opcodes (FTMS §4.16)
OP_REQUEST_CONTROL = 0x00
OP_RESET = 0x01
OP_SET_TARGET_RESISTANCE = 0x04
OP_SET_TARGET_POWER = 0x05
OP_START_RESUME = 0x07
OP_STOP_PAUSE = 0x08
OP_RESPONSE = 0x80

RESULT_SUCCESS = 0x01


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _s16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<h", data, offset)[0]


def parse_indoor_bike_data(data: bytes) -> dict[str, float]:
    """Parse FTMS Indoor Bike Data (0x2AD2) notification payload.

    Flags (uint16 LE) indicate which optional fields follow. Instantaneous
    speed is present when bit0 is clear (more_data=0). Instantaneous cadence
    when bit2 set. Instantaneous power when bit6 set.
    """
    if len(data) < 2:
        return {}

    flags = _u16(data, 0)
    offset = 2
    out: dict[str, float] = {}

    more_data = bool(flags & 0x0001)
    average_speed = bool(flags & 0x0002)
    instantaneous_cadence = bool(flags & 0x0004)
    average_cadence = bool(flags & 0x0008)
    total_distance = bool(flags & 0x0010)
    resistance_level = bool(flags & 0x0020)
    instantaneous_power = bool(flags & 0x0040)
    average_power = bool(flags & 0x0080)
    expended_energy = bool(flags & 0x0100)
    heart_rate = bool(flags & 0x0200)
    metabolic_equivalent = bool(flags & 0x0400)
    elapsed_time = bool(flags & 0x0800)
    remaining_time = bool(flags & 0x1000)

    # Instantaneous Speed present when More Data bit is 0
    if not more_data:
        if offset + 2 > len(data):
            return out
        # unit: 0.01 km/h
        out["speed_kmh"] = _u16(data, offset) / 100.0
        offset += 2

    if average_speed:
        offset += 2

    if instantaneous_cadence:
        if offset + 2 > len(data):
            return out
        # unit: 0.5 rpm
        out["cadence_rpm"] = _u16(data, offset) / 2.0
        offset += 2

    if average_cadence:
        offset += 2

    if total_distance:
        offset += 3

    if resistance_level:
        if offset + 2 > len(data):
            return out
        out["resistance_raw"] = float(_s16(data, offset))
        offset += 2

    if instantaneous_power:
        if offset + 2 > len(data):
            return out
        out["power_w"] = float(_s16(data, offset))
        offset += 2

    if average_power:
        offset += 2

    if expended_energy:
        offset += 5

    if heart_rate:
        offset += 1

    if metabolic_equivalent:
        offset += 1

    if elapsed_time:
        offset += 2

    if remaining_time:
        offset += 2

    return out


def parse_resistance_range(data: bytes) -> ResistanceRange:
    """Supported Resistance Level Range: min, max, step as sint16 * 0.1."""
    if len(data) < 6:
        return ResistanceRange()
    min_raw, max_raw, step_raw = struct.unpack("<hhh", data[:6])
    # Expose as percent of max when max > 0; otherwise raw * 10
    if max_raw > 0:
        return ResistanceRange(
            min_pct=max(0.0, (min_raw / max_raw) * 100.0),
            max_pct=100.0,
            step_pct=max(0.1, (step_raw / max_raw) * 100.0) if step_raw else 1.0,
        )
    return ResistanceRange(
        min_pct=min_raw * 0.1,
        max_pct=max_raw * 0.1 if max_raw else 100.0,
        step_pct=step_raw * 0.1 if step_raw else 1.0,
    )


def parse_power_range(data: bytes) -> PowerRange:
    if len(data) < 6:
        return PowerRange()
    min_w, max_w, step_w = struct.unpack("<hhh", data[:6])
    return PowerRange(
        min_w=int(min_w),
        max_w=int(max_w) if max_w > 0 else 1000,
        step_w=int(step_w) if step_w > 0 else 1,
    )


class RealFtmsBleak(TrainerBackend):
    """Live FTMS Indoor Bike over Bleak."""

    def __init__(self) -> None:
        super().__init__()
        self._client = None  # bleak.BleakClient when connected
        self._state = ConnectionState.DISCONNECTED
        self._mode = ControlMode.IDLE
        self._metrics = TrainerMetrics()
        self._resistance_range = ResistanceRange()
        self._power_range = PowerRange()
        self._control_event = asyncio.Event()
        self._last_cp_result: Optional[int] = None
        self._max_resistance_raw = 1000  # for % -> raw conversion
        self._lock = asyncio.Lock()

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
        from bleak import BleakScanner

        self._set_state(ConnectionState.SCANNING, "Scanning for FTMS…")
        found: dict[str, DiscoveredDevice] = {}

        def _detection(device, advertisement_data) -> None:
            uuids = [u.lower() for u in (advertisement_data.service_uuids or [])]
            name = device.name or advertisement_data.local_name or ""
            has_ftms = FTMS_SERVICE.lower() in uuids or any(
                u.endswith("1826") for u in uuids
            )
            # Also keep devices that look like trainers by name
            name_l = name.lower()
            looks_trainer = any(
                k in name_l
                for k in ("tacx", "trainer", "neo", "flux", "smart", "kickr", "wattbike")
            )
            if not (has_ftms or looks_trainer):
                return
            addr = device.address
            found[addr] = DiscoveredDevice(
                address=addr,
                name=name or addr,
                rssi=advertisement_data.rssi,
            )

        try:
            async with BleakScanner(detection_callback=_detection):
                await asyncio.sleep(timeout_s)
        except Exception as exc:
            log.exception("Scan failed")
            self._set_state(ConnectionState.ERROR, f"Scan failed: {exc}")
            raise

        devices = sorted(
            found.values(),
            key=lambda d: d.rssi if d.rssi is not None else -999,
            reverse=True,
        )
        self._set_state(ConnectionState.DISCONNECTED, f"Found {len(devices)} device(s)")
        return devices

    async def connect(self, address: Optional[str] = None) -> None:
        from bleak import BleakClient

        if address is None:
            devices = await self.scan()
            if not devices:
                self._set_state(ConnectionState.ERROR, "No FTMS trainer found")
                raise RuntimeError("No FTMS trainer found")
            address = devices[0].address

        self._set_state(ConnectionState.CONNECTING, f"Connecting to {address}…")
        client = BleakClient(address)
        try:
            await client.connect()
            self._client = client

            await self._read_ranges()
            await client.start_notify(INDOOR_BIKE_DATA, self._on_bike_data)
            try:
                await client.start_notify(CONTROL_POINT, self._on_control_point)
            except Exception:
                # Some stacks use indicate; Bleak maps start_notify to both
                log.warning("Control Point notify/indicate setup warning", exc_info=True)

            try:
                await client.start_notify(MACHINE_STATUS, self._on_machine_status)
            except Exception:
                log.debug("Machine Status characteristic not available")

            await self.request_control()
            # Start/resume so trainer accepts targets
            try:
                await self._write_cp(bytes([OP_START_RESUME]))
            except Exception:
                log.debug("Start/Resume optional", exc_info=True)

            self._set_state(ConnectionState.CONNECTED, address)
        except Exception as exc:
            self._client = None
            self._set_state(ConnectionState.ERROR, str(exc))
            raise

    async def disconnect(self) -> None:
        client = self._client
        self._client = None
        if client and client.is_connected:
            try:
                await client.disconnect()
            except Exception:
                log.debug("Disconnect error", exc_info=True)
        self._mode = ControlMode.IDLE
        self._set_state(ConnectionState.DISCONNECTED, "Disconnected")

    async def _read_ranges(self) -> None:
        assert self._client is not None
        try:
            raw = await self._client.read_gatt_char(SUPPORTED_RESISTANCE_RANGE)
            if len(raw) >= 6:
                min_raw, max_raw, step_raw = struct.unpack("<hhh", raw[:6])
                self._max_resistance_raw = max_raw if max_raw > 0 else 1000
                self._resistance_range = parse_resistance_range(raw)
        except Exception:
            log.debug("Resistance range not available; using defaults", exc_info=True)

        try:
            raw = await self._client.read_gatt_char(SUPPORTED_POWER_RANGE)
            self._power_range = parse_power_range(raw)
        except Exception:
            log.debug("Power range not available; using defaults", exc_info=True)

    def _on_bike_data(self, _handle: int, data: bytearray) -> None:
        parsed = parse_indoor_bike_data(bytes(data))
        m = self._metrics
        if "power_w" in parsed:
            m.power_w = parsed["power_w"]
        if "cadence_rpm" in parsed:
            m.cadence_rpm = parsed["cadence_rpm"]
        if "speed_kmh" in parsed:
            m.speed_kmh = parsed["speed_kmh"]
        self._emit_metrics(m)

    def _on_control_point(self, _handle: int, data: bytearray) -> None:
        if len(data) >= 3 and data[0] == OP_RESPONSE:
            self._last_cp_result = data[2]
            self._control_event.set()
            if data[2] != RESULT_SUCCESS:
                log.warning(
                    "Control Point response: opcode=0x%02x result=0x%02x",
                    data[1],
                    data[2],
                )

    def _on_machine_status(self, _handle: int, data: bytearray) -> None:
        log.debug("Machine status: %s", data.hex())

    async def _write_cp(self, payload: bytes, timeout_s: float = 3.0) -> None:
        if self._client is None or not self._client.is_connected:
            raise RuntimeError("Not connected")
        async with self._lock:
            self._control_event.clear()
            self._last_cp_result = None
            await self._client.write_gatt_char(CONTROL_POINT, payload, response=True)
            try:
                await asyncio.wait_for(self._control_event.wait(), timeout=timeout_s)
            except asyncio.TimeoutError:
                log.warning("Control Point response timeout for %s", payload.hex())
                return
            if self._last_cp_result not in (None, RESULT_SUCCESS):
                raise RuntimeError(
                    f"Control Point rejected (result=0x{self._last_cp_result:02x})"
                )

    async def request_control(self) -> None:
        await self._write_cp(bytes([OP_REQUEST_CONTROL]))

    async def set_target_power(self, watts: int) -> None:
        pr = self._power_range
        watts = max(pr.min_w, min(pr.max_w, int(watts)))
        payload = struct.pack("<Bh", OP_SET_TARGET_POWER, watts)
        await self._write_cp(payload)
        self._mode = ControlMode.ERG
        self._metrics.target_power_w = float(watts)
        self._metrics.resistance_pct = None
        self._emit_metrics(self._metrics)

    async def set_resistance(self, percent: float) -> None:
        rr = self._resistance_range
        percent = max(rr.min_pct, min(rr.max_pct, float(percent)))
        # FTMS Set Target Resistance Level: uint8, unit 0.1 of resistance
        raw = int(round((percent / 100.0) * self._max_resistance_raw / 10.0))
        raw = max(0, min(255, raw))
        payload = bytes([OP_SET_TARGET_RESISTANCE, raw])
        await self._write_cp(payload)
        self._mode = ControlMode.RESISTANCE
        self._metrics.resistance_pct = percent
        self._metrics.target_power_w = None
        self._emit_metrics(self._metrics)
