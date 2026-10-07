# Tacx Desktop

Windows-first **desktop** remote for Tacx (and other) smart trainers over **public FTMS BLE**.

Not a Connect IQ / watch app. Not private Tacx BLE. Not ANT+ / FE-C simulation / FIT logging.

Stack: **Python 3.12+**, **Bleak** (WinRT backend on Windows), **CustomTkinter** UI, optional **pycycling** helpers.

## What it does (v1)

| Feature | Demo mode | Real trainer |
| --- | --- | --- |
| Scan / connect FTMS Indoor Bike (`0x1826`) | Stub devices | Live BLE |
| Live power, cadence, speed + connection status | Simulated | Indoor Bike Data `0x2AD2` |
| ERG target watts with ± steps (5 / 10 / 25) | Yes | Control Point `0x2AD9` Set Target Power |
| Resistance % (range from Supported Resistance Level Range when available) | Fixed 0–100% | Live range + Set Target Resistance |
| Interval presets (10×30/30, 5×3/2, 4×4/3) swapping ERG + timer | Yes | Yes |
| Clear **DEMO** badge | Always | — |

## Requirements (Windows)

1. **Windows 10/11** with Bluetooth LE (built-in or USB dongle).
2. **Python 3.12+**.
3. Trainer paired / radio on; stand within a few meters.
4. **Quit other apps that hold the trainer BLE link** before connecting:
   - Zwift, Tacx Training / Tacx Desktop, MyWhoosh, Rouvy, TrainerRoad, etc.
   - Only one BLE client can typically control FTMS at a time.

Linux/macOS may work with Bleak but are not the primary target; use `--demo` / `--headless-demo` for UI/logic smoke tests without hardware.

## Install

```powershell
git clone https://github.com/nielsver/tacx-desktop.git
cd tacx-desktop
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
pip install -e .
```

## Run

```powershell
# Real trainer (Windows + BLE)
python -m tacx_desktop

# Demo UI (no trainer) — shows red DEMO badge
python -m tacx_desktop --demo

# Headless smoke test (CI / no display) — exercises demo backend + intervals
python -m tacx_desktop --headless-demo
```

Or after install: `tacx-desktop`, `tacx-desktop --demo`, `tacx-desktop --headless-demo`.

### Connect flow

1. Close Zwift / Tacx Training / other FTMS clients.
2. Power on the trainer.
3. Click **Scan** → select your bike → **Connect**.
4. Use **ERG** (± steps or Set watts), **Resistance** slider, or start an **interval preset**.

## Architecture

```
TrainerBackend (ABC)
├── RealFtmsBleak   # Bleak GATT: notify 0x2AD2, indicate/write 0x2AD9
└── DemoStub        # Simulated metrics + control (is_demo=True)

UI (CustomTkinter) + IntervalEngine → set_target_power / set_resistance
```

Package layout:

```
tacx_desktop/
  backend.py          # interface + metrics/state types
  ble_ftms.py         # RealFtmsBleak + Indoor Bike Data parser
  demo_backend.py     # DemoStub
  interval_timer.py   # presets + timer
  ui_app.py           # CustomTkinter app
  main.py             # CLI entry
```

### FTMS (public) — what we use

| Role | UUID | Notes |
| --- | --- | --- |
| Fitness Machine Service | `0x1826` | Scan filter / service |
| Indoor Bike Data | `0x2AD2` | Notify — power, cadence, speed |
| Fitness Machine Control Point | `0x2AD9` | Indicate + write — Request Control, Set Target Power, Set Resistance |
| Supported Resistance Level Range | `0x2AD6` | Optional read for % bounds |
| Supported Power Range | `0x2AD8` | Optional read for watt clamp |

Typical control sequence:

1. Connect + start notify on Indoor Bike Data.
2. Enable Control Point indications.
3. **Request Control** (`0x00`).
4. Optional **Start/Resume** (`0x07`).
5. **Set Target Power** (`0x05`, sint16 watts) or **Set Target Resistance Level** (`0x04`, uint8 × 0.1).

## Protocol context (from research notes)

Smart trainers commonly expose:

| Interface | Role |
| --- | --- |
| **FTMS** (BLE) | Standard control + feedback (resistance, target power, indoor bike data) — **this app** |
| **CPS** / **CSC** (BLE) | Power / speed-cadence measurement only |
| **ANT+ FE-C** | Grade, wind, drafting, simulation — **out of scope** |
| **Private Tacx BLE** | Vendor extras (e.g. Road Feel) — **out of scope** (docs not fully public) |

Control modes: **Resistance**, **ERG / target power**, **Simulation** (grade/wind — not in v1).

Prefer public FTMS first; treat private Tacx BLE as optional and blocked on documentation.

## Non-goals (v1)

- Connect IQ / watch remotes  
- Private Tacx BLE / Road Feel / virtual gear  
- Grade / simulation / FE-C  
- FIT recording  
- ANT+  
- Multi-trainer  

## Tests

```powershell
pip install pytest pytest-asyncio
pytest -q
python -m tacx_desktop --headless-demo
```

## License

MIT
