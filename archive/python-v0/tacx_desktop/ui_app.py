"""CustomTkinter UI for Tacx Desktop trainer remote."""

from __future__ import annotations

import asyncio
import logging
import threading
import tkinter as tk
from typing import Optional

import customtkinter as ctk

from tacx_desktop.backend import ConnectionState, ControlMode, TrainerBackend, TrainerMetrics
from tacx_desktop.demo_backend import DemoStub
from tacx_desktop.interval_timer import PRESETS, IntervalEngine, IntervalPreset

log = logging.getLogger(__name__)

ERG_STEPS = (5, 10, 25)


class AsyncBridge:
    """Run an asyncio loop in a background thread; schedule coroutines from Tk."""

    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name="asyncio-bridge", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def submit(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop)

    def stop(self) -> None:
        self.loop.call_soon_threadsafe(self.loop.stop)


class TacxDesktopApp(ctk.CTk):
    def __init__(self, backend: TrainerBackend, *, title_suffix: str = "") -> None:
        super().__init__()
        self.backend = backend
        self.bridge = AsyncBridge()
        self.bridge.start()

        self._target_watts = 150
        self._resistance_pct = 20.0
        self._erg_step = 10
        self._devices: list = []
        self._closing = False

        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("blue")

        demo_tag = "  [DEMO]" if backend.is_demo else ""
        self.title(f"Tacx Desktop{demo_tag}{title_suffix}")
        self.geometry("920x680")
        self.minsize(800, 560)

        self.interval = IntervalEngine(
            on_tick=self._on_interval_tick,
            on_target=self._on_interval_target,
        )

        backend.on_metrics = self._on_metrics
        backend.on_state = self._on_state

        self._build()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(200, self._poll_ui)

        if backend.is_demo:
            self._show_demo_badge()

    # ----- layout -----

    def _build(self) -> None:
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        # Header / connection
        header = ctk.CTkFrame(self)
        header.grid(row=0, column=0, sticky="ew", padx=12, pady=(12, 6))
        header.grid_columnconfigure(2, weight=1)

        self.demo_badge = ctk.CTkLabel(
            header,
            text="DEMO",
            fg_color="#c0392b",
            text_color="white",
            corner_radius=6,
            width=70,
            font=ctk.CTkFont(size=14, weight="bold"),
        )
        # Hidden unless demo
        self._demo_visible = False

        self.status_label = ctk.CTkLabel(
            header, text="Disconnected", font=ctk.CTkFont(size=14, weight="bold")
        )
        self.status_label.grid(row=0, column=0, padx=8, pady=8, sticky="w")

        self.device_menu = ctk.CTkOptionMenu(header, values=["(scan first)"], width=260)
        self.device_menu.grid(row=0, column=1, padx=8, pady=8)

        self.scan_btn = ctk.CTkButton(header, text="Scan", width=90, command=self._scan)
        self.scan_btn.grid(row=0, column=2, padx=4, pady=8, sticky="e")

        self.connect_btn = ctk.CTkButton(header, text="Connect", width=100, command=self._connect)
        self.connect_btn.grid(row=0, column=3, padx=4, pady=8)

        self.disconnect_btn = ctk.CTkButton(
            header, text="Disconnect", width=110, command=self._disconnect, state="disabled"
        )
        self.disconnect_btn.grid(row=0, column=4, padx=8, pady=8)

        # Metrics
        metrics = ctk.CTkFrame(self)
        metrics.grid(row=1, column=0, sticky="ew", padx=12, pady=6)
        for i in range(4):
            metrics.grid_columnconfigure(i, weight=1)

        self.power_var = tk.StringVar(value="— W")
        self.cadence_var = tk.StringVar(value="— rpm")
        self.speed_var = tk.StringVar(value="— km/h")
        self.target_var = tk.StringVar(value="Target: —")

        self._metric_card(metrics, 0, "Power", self.power_var)
        self._metric_card(metrics, 1, "Cadence", self.cadence_var)
        self._metric_card(metrics, 2, "Speed", self.speed_var)
        self._metric_card(metrics, 3, "Control", self.target_var)

        # Body: ERG | Resistance | Intervals
        body = ctk.CTkFrame(self)
        body.grid(row=2, column=0, sticky="nsew", padx=12, pady=6)
        body.grid_columnconfigure((0, 1, 2), weight=1)
        body.grid_rowconfigure(0, weight=1)

        self._build_erg(body)
        self._build_resistance(body)
        self._build_intervals(body)

        # Footer
        foot = ctk.CTkFrame(self, fg_color="transparent")
        foot.grid(row=3, column=0, sticky="ew", padx=12, pady=(6, 12))
        self.hint = ctk.CTkLabel(
            foot,
            text="Close Zwift / Tacx Training / MyWhoosh before connecting — only one BLE client can control the trainer.",
            font=ctk.CTkFont(size=12),
            text_color=("gray30", "gray70"),
            wraplength=880,
            justify="left",
        )
        self.hint.pack(anchor="w")

    def _metric_card(self, parent, col: int, title: str, var: tk.StringVar) -> None:
        frame = ctk.CTkFrame(parent)
        frame.grid(row=0, column=col, padx=8, pady=8, sticky="nsew")
        ctk.CTkLabel(frame, text=title, font=ctk.CTkFont(size=12)).pack(pady=(10, 2))
        ctk.CTkLabel(frame, textvariable=var, font=ctk.CTkFont(size=28, weight="bold")).pack(
            pady=(2, 12)
        )

    def _build_erg(self, parent) -> None:
        frame = ctk.CTkFrame(parent)
        frame.grid(row=0, column=0, padx=8, pady=8, sticky="nsew")
        ctk.CTkLabel(frame, text="ERG mode", font=ctk.CTkFont(size=16, weight="bold")).pack(
            pady=(12, 8)
        )

        self.erg_display = ctk.CTkLabel(
            frame, text=f"{self._target_watts} W", font=ctk.CTkFont(size=36, weight="bold")
        )
        self.erg_display.pack(pady=8)

        step_row = ctk.CTkFrame(frame, fg_color="transparent")
        step_row.pack(pady=4)
        ctk.CTkLabel(step_row, text="Step:").pack(side="left", padx=4)
        self.step_menu = ctk.CTkSegmentedButton(
            step_row, values=[str(s) for s in ERG_STEPS], command=self._on_step_change
        )
        self.step_menu.set(str(self._erg_step))
        self.step_menu.pack(side="left", padx=4)

        btn_row = ctk.CTkFrame(frame, fg_color="transparent")
        btn_row.pack(pady=10)
        ctk.CTkButton(btn_row, text="−", width=70, command=lambda: self._nudge_erg(-1)).pack(
            side="left", padx=6
        )
        ctk.CTkButton(btn_row, text="+", width=70, command=lambda: self._nudge_erg(1)).pack(
            side="left", padx=6
        )

        ctk.CTkButton(frame, text="Apply ERG", command=self._apply_erg).pack(pady=12, padx=16, fill="x")

        entry_row = ctk.CTkFrame(frame, fg_color="transparent")
        entry_row.pack(pady=8, padx=16, fill="x")
        self.erg_entry = ctk.CTkEntry(entry_row, placeholder_text="Watts")
        self.erg_entry.pack(side="left", fill="x", expand=True, padx=(0, 8))
        ctk.CTkButton(entry_row, text="Set", width=60, command=self._set_erg_from_entry).pack(
            side="left"
        )

    def _build_resistance(self, parent) -> None:
        frame = ctk.CTkFrame(parent)
        frame.grid(row=0, column=1, padx=8, pady=8, sticky="nsew")
        ctk.CTkLabel(
            frame, text="Resistance mode", font=ctk.CTkFont(size=16, weight="bold")
        ).pack(pady=(12, 8))

        rr = self.backend.get_resistance_range()
        self.res_label = ctk.CTkLabel(
            frame,
            text=f"{self._resistance_pct:.0f} %",
            font=ctk.CTkFont(size=36, weight="bold"),
        )
        self.res_label.pack(pady=8)

        self.res_slider = ctk.CTkSlider(
            frame,
            from_=rr.min_pct,
            to=rr.max_pct,
            number_of_steps=max(1, int((rr.max_pct - rr.min_pct) / max(rr.step_pct, 0.1))),
            command=self._on_res_slide,
        )
        self.res_slider.set(self._resistance_pct)
        self.res_slider.pack(pady=12, padx=20, fill="x")

        self.res_range_hint = ctk.CTkLabel(
            frame,
            text=f"Range {rr.min_pct:.0f}–{rr.max_pct:.0f}% (step {rr.step_pct:.1f})",
            font=ctk.CTkFont(size=12),
            text_color=("gray40", "gray60"),
        )
        self.res_range_hint.pack(pady=4)

        ctk.CTkButton(frame, text="Apply Resistance", command=self._apply_resistance).pack(
            pady=12, padx=16, fill="x"
        )

    def _build_intervals(self, parent) -> None:
        frame = ctk.CTkFrame(parent)
        frame.grid(row=0, column=2, padx=8, pady=8, sticky="nsew")
        ctk.CTkLabel(
            frame, text="Interval presets", font=ctk.CTkFont(size=16, weight="bold")
        ).pack(pady=(12, 8))

        self.interval_status = ctk.CTkLabel(
            frame, text="Idle", font=ctk.CTkFont(size=14), wraplength=240
        )
        self.interval_status.pack(pady=8, padx=8)

        for preset in PRESETS:
            ctk.CTkButton(
                frame,
                text=preset.label,
                command=lambda p=preset: self._start_interval(p),
            ).pack(pady=4, padx=16, fill="x")
            ctk.CTkLabel(
                frame,
                text=f"{preset.work_watts}W / {preset.rest_watts}W — {preset.description}",
                font=ctk.CTkFont(size=11),
                text_color=("gray40", "gray60"),
                wraplength=240,
                justify="left",
            ).pack(padx=16, anchor="w")

        ctk.CTkButton(
            frame, text="Stop intervals", fg_color="#7f8c8d", command=self._stop_interval
        ).pack(pady=16, padx=16, fill="x")

    def _show_demo_badge(self) -> None:
        if not self._demo_visible:
            self.demo_badge.grid(row=0, column=5, padx=(4, 8), pady=8)
            self._demo_visible = True

    # ----- backend callbacks (may be off main thread) -----

    def _on_metrics(self, m: TrainerMetrics) -> None:
        self.after(0, lambda: self._apply_metrics(m))

    def _on_state(self, state: ConnectionState, detail: str) -> None:
        self.after(0, lambda: self._apply_state(state, detail))

    def _apply_metrics(self, m: TrainerMetrics) -> None:
        self.power_var.set(f"{m.power_w:.0f} W")
        self.cadence_var.set(f"{m.cadence_rpm:.0f} rpm")
        self.speed_var.set(f"{m.speed_kmh:.1f} km/h")
        if m.target_power_w is not None:
            self.target_var.set(f"ERG {m.target_power_w:.0f} W")
        elif m.resistance_pct is not None:
            self.target_var.set(f"Res {m.resistance_pct:.0f}%")
        else:
            mode = self.backend.get_mode()
            self.target_var.set(mode.name.title() if mode != ControlMode.IDLE else "Idle")

    def _apply_state(self, state: ConnectionState, detail: str) -> None:
        text = state.name.title()
        if detail:
            text = f"{text}: {detail}"
        self.status_label.configure(text=text)
        connected = state == ConnectionState.CONNECTED
        self.connect_btn.configure(state="disabled" if connected else "normal")
        self.disconnect_btn.configure(state="normal" if connected else "disabled")
        # Refresh resistance slider bounds after connect (real trainer ranges)
        if connected:
            rr = self.backend.get_resistance_range()
            self.res_slider.configure(
                from_=rr.min_pct,
                to=rr.max_pct,
                number_of_steps=max(1, int((rr.max_pct - rr.min_pct) / max(rr.step_pct, 0.1))),
            )
            self.res_range_hint.configure(
                text=f"Range {rr.min_pct:.0f}–{rr.max_pct:.0f}% (step {rr.step_pct:.1f})"
            )

    def _on_interval_tick(self, engine: IntervalEngine) -> None:
        self.after(0, lambda: self.interval_status.configure(text=engine.status_text))

    async def _on_interval_target(self, watts: int) -> None:
        self._target_watts = watts
        self.after(0, lambda: self.erg_display.configure(text=f"{watts} W"))
        await self.backend.set_target_power(watts)

    # ----- UI actions -----

    def _on_step_change(self, value: str) -> None:
        self._erg_step = int(value)

    def _nudge_erg(self, direction: int) -> None:
        self._target_watts = max(0, self._target_watts + direction * self._erg_step)
        self.erg_display.configure(text=f"{self._target_watts} W")

    def _set_erg_from_entry(self) -> None:
        raw = self.erg_entry.get().strip()
        try:
            self._target_watts = max(0, int(raw))
        except ValueError:
            return
        self.erg_display.configure(text=f"{self._target_watts} W")
        self._apply_erg()

    def _apply_erg(self) -> None:
        watts = self._target_watts
        self.bridge.submit(self.backend.set_target_power(watts))

    def _on_res_slide(self, value: float) -> None:
        self._resistance_pct = float(value)
        self.res_label.configure(text=f"{self._resistance_pct:.0f} %")

    def _apply_resistance(self) -> None:
        self.bridge.submit(self.backend.set_resistance(self._resistance_pct))

    def _scan(self) -> None:
        self.status_label.configure(text="Scanning…")
        fut = self.bridge.submit(self.backend.scan())

        def _done(f):
            try:
                devices = f.result()
            except Exception as exc:
                self.after(0, lambda: self.status_label.configure(text=f"Scan error: {exc}"))
                return
            self.after(0, lambda: self._populate_devices(devices))

        fut.add_done_callback(_done)

    def _populate_devices(self, devices) -> None:
        self._devices = devices
        if not devices:
            self.device_menu.configure(values=["(none found)"])
            self.device_menu.set("(none found)")
            return
        labels = [f"{d.name} [{d.address}]" for d in devices]
        self.device_menu.configure(values=labels)
        self.device_menu.set(labels[0])

    def _selected_address(self) -> Optional[str]:
        label = self.device_menu.get()
        for d in self._devices:
            if f"{d.name} [{d.address}]" == label:
                return d.address
        if self._devices:
            return self._devices[0].address
        return None

    def _connect(self) -> None:
        addr = self._selected_address()
        self.bridge.submit(self.backend.connect(addr))

    def _disconnect(self) -> None:
        self.bridge.submit(self._stop_interval_async())
        self.bridge.submit(self.backend.disconnect())

    def _start_interval(self, preset: IntervalPreset) -> None:
        self.bridge.submit(self.interval.start(preset))

    def _stop_interval(self) -> None:
        self.bridge.submit(self.interval.stop())

    async def _stop_interval_async(self) -> None:
        await self.interval.stop()

    def _poll_ui(self) -> None:
        if self._closing:
            return
        # Keep interval label fresh even if ticks are sparse
        if self.interval.running:
            self.interval_status.configure(text=self.interval.status_text)
        self.after(500, self._poll_ui)

    def _on_close(self) -> None:
        self._closing = True
        try:
            fut = self.bridge.submit(self._shutdown())
            fut.result(timeout=5)
        except Exception:
            log.debug("Shutdown error", exc_info=True)
        self.bridge.stop()
        self.destroy()

    async def _shutdown(self) -> None:
        await self.interval.stop()
        await self.backend.disconnect()


def run_ui(*, demo: bool = False) -> None:
    if demo:
        backend: TrainerBackend = DemoStub()
    else:
        from tacx_desktop.ble_ftms import RealFtmsBleak

        backend = RealFtmsBleak()
    app = TacxDesktopApp(backend)
    app.mainloop()
