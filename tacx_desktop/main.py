"""CLI entry: GUI (default) or headless demo smoke path."""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="tacx-desktop",
        description="Windows-first Tacx trainer remote over public FTMS BLE",
    )
    p.add_argument(
        "--demo",
        action="store_true",
        help="Use DemoStub backend (no BLE) and show DEMO badge in UI",
    )
    p.add_argument(
        "--headless-demo",
        action="store_true",
        help="Run a CLI smoke test of demo backend + ERG + intervals (no GUI)",
    )
    p.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Debug logging",
    )
    return p


async def run_headless_demo(seconds: float = 6.0) -> int:
    """Exercise DemoStub + IntervalEngine without a display."""
    from tacx_desktop.demo_backend import DemoStub
    from tacx_desktop.interval_timer import PRESETS, IntervalEngine

    logging.info("Starting headless demo smoke test…")
    backend = DemoStub()
    events: list[str] = []

    def on_metrics(m):
        events.append(
            f"metrics power={m.power_w:.0f} cad={m.cadence_rpm:.0f} spd={m.speed_kmh:.1f}"
        )

    def on_state(state, detail):
        events.append(f"state {state.name} {detail}".strip())

    backend.on_metrics = on_metrics
    backend.on_state = on_state

    devices = await backend.scan(timeout_s=0.5)
    assert devices, "demo scan should return devices"
    await backend.connect(devices[0].address)
    await backend.set_target_power(200)
    await asyncio.sleep(0.8)
    m = backend.get_metrics()
    assert m.target_power_w == 200
    assert m.power_w > 0, "demo should simulate power"

    await backend.set_resistance(40.0)
    await asyncio.sleep(0.5)
    assert backend.get_metrics().resistance_pct == 40.0

    # Short custom-like preset via first preset but we only run briefly
    preset = PRESETS[0]
    ticks: list[str] = []

    async def on_target(watts: int) -> None:
        await backend.set_target_power(watts)
        ticks.append(f"target={watts}")

    engine = IntervalEngine(
        on_tick=lambda e: ticks.append(e.status_text),
        on_target=on_target,
    )
    await engine.start(preset)
    await asyncio.sleep(min(seconds, 2.5))
    assert engine.running or engine.phase.name in ("WORK", "REST", "DONE")
    assert any("target=" in t for t in ticks), "interval should set ERG targets"
    await engine.stop()

    await backend.set_target_power(150)
    await backend.disconnect()

    print("HEADLESS DEMO OK")
    print(f"  devices: {[d.name for d in devices]}")
    print(f"  last power: {m.power_w:.0f} W")
    print(f"  interval ticks: {len(ticks)}")
    print(f"  state events: {len(events)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.headless_demo:
        return asyncio.run(run_headless_demo())

    # GUI path
    try:
        from tacx_desktop.ui_app import run_ui
    except Exception as exc:
        print(
            f"UI import failed ({exc}). On headless systems use: "
            f"python -m tacx_desktop --headless-demo",
            file=sys.stderr,
        )
        return 1

    run_ui(demo=args.demo)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
