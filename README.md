# Tacx Desktop

Cross-platform **desktop** remote for Tacx (and other) smart trainers.

**Stack:** Flutter UI + Rust trainer core (`btleplug`) via [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/).

> **Note:** The earlier Python / CustomTkinter / Bleak scaffold lived here as v0. It was replaced by this Flutter + Rust app. See [`archive/python-v0/`](archive/python-v0/) for the historical code.

Not a Connect IQ / watch app. Not private Tacx Road Feel. Not ANT+ radio (FE-C here is **over BLE**, Tacx UART).

## Features

| Feature | Demo mode | Real trainer |
| --- | --- | --- |
| Scan / connect | Stub devices | Live BLE |
| Auto protocol | Demo | **FTMS first**, then **Tacx FE-C-over-BLE** fallback |
| Live power, cadence, speed | Simulated | FTMS Indoor Bike Data / FE-C pages 16+25 |
| ERG target watts (± 5 / 10 / 25) | Yes | FTMS Control Point or FE-C target power |
| Resistance % | Yes | FTMS Supported Resistance Level Range + Set Resistance; FE-C basic resistance 0–200 N mapped from % |
| Interval presets (10×30/30, 5×3/2, 4×4/3) | Yes | Yes |
| Exclusive-control messaging | Hint banner | Clear errors for busy trainer / NOCTRL |
| FTMS Control Point indications | — | Parsed (`0x80`); NOCTRL / failures surface in UI |
| GATT inventory on connect | — | UUID/property table + FTMS vs FE-C class in logs |
| Link-lost → Reconnect | Simulated disconnect N/A | Auto Error state; Reconnect restores interval ERG |
| FE-C write rate limit | — | ~4 Hz latest-wins coalesce on UART WithoutResponse |
| FE-C Track / Wind / User-config | Demo simulates grade | Pages `0x33` / `0x32` / `0x37` + Flutter Simulation panel |
| FTMS Indoor Bike Simulation | Demo grade feel | Opcode `0x11` + Crr/Cw sliders when Feature bit 13 set |
| Fitness Machine Status | — | Subscribe `0x2ADA`; stop/pause banner; control-lost → Error |
| DEMO badge | Always when demo on | — |

## Platforms

| OS | Status | Notes |
| --- | --- | --- |
| **Windows** | Supported | Bleak/btleplug WinRT BLE; build with Visual Studio + Flutter Windows desktop |
| **Linux** | Supported | Needs **BlueZ** + D-Bus; portable binary via `flutter build linux` |
| **macOS** | Supported | Enable **Bluetooth** permission for the app (entitlements included) |

“All distros” on Linux means: a portable Flutter Linux binary **or** `flutter run -d linux` / source build on common distros with BlueZ. We do not ship every distro’s native `.deb`/`.rpm` packager.


## Windows quickstart

1. **Prereqs:** Flutter 3.29+, Rust (`rustup`), Visual Studio **Desktop development with C++**, Windows 10/11 BLE.
2. **Clone & run (demo first):**
   ```powershell
   git clone https://github.com/nielsver/tacx-desktop.git
   cd tacx-desktop
   flutter pub get
   flutter run -d windows
   ```
   Leave the red **DEMO** toggle on — try ERG, Resistance, Intervals, and Simulation (grade / wind / Crr / Cw) without a trainer.
3. **Live trainer:** turn **Demo** off. Quit Zwift / Tacx Training / MyWhoosh / TrainerRoad. In **Settings → Bluetooth**, **remove/forget** the trainer so it is **unpaired**. Power the trainer → **Scan** → **Connect**.
4. **Release zip:** `flutter build windows --release` → zip `build\windows\x64\runner\Release\`, or `./scripts/build_release.sh windows`.

## Requirements

1. Flutter **3.29+** (Dart 3.7+) and Rust **1.75+** (`rustup`).
2. Bluetooth LE adapter.
3. Trainer powered on; stand nearby.
4. **Quit other apps that hold the trainer BLE link** before connecting:
   - Zwift, Tacx Training / Tacx Desktop, MyWhoosh, Rouvy, TrainerRoad, etc.
   - Only one BLE client can typically control FTMS / Tacx FE-C at a time.

### Linux (BlueZ)

```bash
# Debian/Ubuntu/Fedora-family examples — package names vary
sudo apt install bluez bluetooth libdbus-1-dev
# Ensure your user can use Bluetooth (often group `bluetooth` or via polkit)
sudo usermod -aG bluetooth "$USER"   # then log out/in
systemctl --user status  # D-Bus session must be active for desktop BLE
```

- Keep the scan filter **empty** (this app post-filters by FTMS UUID / Tacx-like names). BlueZ UUID filters are unioned across D-Bus clients and can hide FE-C-only trainers.
- Run as a normal user (no `sudo`); if scan fails, check `bluetoothctl show` and group membership.

### macOS (TCC + entitlements)

- First launch of a **release** `.app` should prompt for Bluetooth (TCC). If scan fails silently: **System Settings → Privacy & Security → Bluetooth** → enable **Tacx Desktop**.
- Debug/Release entitlements include `com.apple.security.device.bluetooth`; Info.plist has `NSBluetoothAlwaysUsageDescription`.
- Prefer connecting from the app only. If you previously **paired** the trainer in macOS Bluetooth settings and control fails, **Forget This Device**, then Connect from Tacx Desktop.

### Windows (leave trainer unpaired)

- Windows 10/11 with BLE (built-in or USB dongle).
- Enable **Developer Mode** if Flutter asks; install Visual Studio C++ desktop workload for Windows builds.
- **Do not OS-pair the trainer** in Settings → Bluetooth. Tacx / FTMS control often breaks when Windows holds a system bond. Remove/forget the device so it is unpaired, quit Zwift / Tacx Training / MyWhoosh, then **Connect** from this app only.
- If the radio is off: Settings → Bluetooth & devices → turn Bluetooth on.

## Install (developers)

```bash
git clone https://github.com/nielsver/tacx-desktop.git
cd tacx-desktop

# Optional: install codegen
cargo install flutter_rust_bridge_codegen

flutter pub get
# After editing Rust under rust/src/api/, regenerate bindings:
flutter_rust_bridge_codegen generate

# Rust unit + headless demo smoke
cd rust && cargo test && cd ..
```

## Run

```bash
# Demo UI (default on first launch — toggle Demo in the header)
flutter run -d linux          # or windows / macos
flutter run -d windows
flutter run -d macos
```

In the app: leave **Demo** on to try the UI without a trainer; turn Demo **off** for live BLE (FTMS → FE-C fallback).

### Headless / CI smoke (Rust)

```bash
cd rust && cargo test --test headless_demo
```

## Build release binaries

```bash
# Helper (linux | windows | macos | all)
./scripts/build_release.sh linux

# Or manually:
flutter build linux --release    # → build/linux/x64/release/bundle/
flutter build windows --release  # → build/windows/x64/runner/Release/
flutter build macos --release    # → build/macos/Build/Products/Release/tacx_desktop.app
```

Ship the Linux `bundle/` folder as-is (includes `lib/` + the Rust **cdylib**). On Windows zip the `Release/` folder. On macOS distribute the `.app` (notarize for Gatekeeper if you ship outside your machine).

### flutter_rust_bridge / cdylib notes

- Rust crate `tacx_desktop_core` builds as `cdylib` + `staticlib` + `rlib` (`rust/Cargo.toml`).
- BLE stack: **btleplug 0.13** (uuid pinned to `=1.26.1` for Rust 1.85+ MSRV; uuid 1.27 wants 1.89).
- After editing `rust/src/api/`, regenerate: `./scripts/gen_bridge.sh` (or `flutter_rust_bridge_codegen generate`).
- Linux runners / local: ensure `LD_LIBRARY_PATH` includes `rust/target/debug` (or release) when loading the native lib outside a full Flutter bundle — see `scripts/test_all.sh`.


## Windows build, run & release (primary desktop target)

### Day-to-day

```powershell
git clone https://github.com/nielsver/tacx-desktop.git
cd tacx-desktop
flutter pub get
flutter run -d windows
```

Requirements: Flutter 3.29+, Rust 1.75+, Visual Studio **Desktop development with C++**, Windows 10/11 BLE.

### Bluetooth — leave the trainer unpaired

1. Quit Zwift / Tacx Training / MyWhoosh / TrainerRoad.
2. In **Settings → Bluetooth & devices**, **Remove** / forget the trainer if it appears as a paired OS device.
3. Power the trainer, **Scan** → **Connect** from Tacx Desktop only.

OS pairing often breaks FTMS exclusive control on Windows.

### Release zip

```powershell
# From Git Bash / WSL / or run the flutter command directly:
flutter build windows --release
# Artifact folder:
#   build\windows\x64\runner\Release\
# Zip that entire Release\ folder (exe + DLLs + data). Helper script:
#   ./scripts/build_release.sh windows   # prints the same path
```

Ship the whole `Release\` directory — it includes the Flutter runner and the Rust **cdylib**.

### Known toolchain pins

| Pin | Why |
| --- | --- |
| `btleplug = "0.13"` | BLE stack (Windows WinRT / Linux BlueZ / macOS) |
| `uuid = "=1.26.1"` | Keep MSRV on Rust **1.85+**; uuid 1.27 wants rustc 1.89 |
| `flutter_rust_bridge = "=2.13.0"` | Matches generated bindings under `lib/src/rust/` |

After editing `rust/src/api/`, run `./scripts/gen_bridge.sh` before relying on new Dart APIs.

## Architecture

```
Flutter (Material 3 ride dashboard)
        │  flutter_rust_bridge
        ▼
Rust crate tacx_desktop_core
  api/trainer.rs     → scan / connect / ERG / resistance / intervals
  trainer/ftms.rs    → FTMS 0x1826 parse + control opcodes
  trainer/fec.rs     → Tacx FE-C-over-BLE UART frames (pycycling-compatible)
  trainer/demo.rs    → simulated metrics
  trainer/controller.rs → FTMS first, FE-C fallback, exclusive-control errors
  btleplug           → Windows / Linux (BlueZ) / macOS BLE
```

### Connect sequence (live)

1. Scan advertisements (FTMS UUID and/or Tacx-like names). Empty `ScanFilter` + post-filter (BlueZ-safe).
2. Connect + discover GATT → **inventory dump** (UUID / properties / class `ftms` | `fec_only` | `dual_ftms_fec`) to stderr / logs.
3. If FTMS Indoor Bike (`0x2AD2`) + Control Point (`0x2AD9`) → **FTMS** path:
   - Subscribe Indoor Bike Data **and** Control Point indications.
   - **Request Control** (`0x00`) → parse CP response (`0x80 …`); fail loudly on **NOCTRL** (`0x05`).
   - **Start/Resume** (`0x07`) → then notify stream for power/cadence/speed.
   - **Set Target Power** (`0x05`) / **Set Resistance** (`0x04`) clamp to Supported Power / Resistance Range and check CP result.
   - Subscribe **Fitness Machine Status** (`0x2ADA`) when present — stop/pause surfaces in UI; **Control Permission Lost** (`0xFF`) → Error + Reconnect. If the characteristic is missing or subscribe fails, connect/control **continues** (soft-fail).
4. Else if Tacx UART RX/TX (`6e40fec3…` / `6e40fec2…`) → **FE-C-over-BLE** path (pages 16+25; cmds `0x30` / `0x31`; simulation `0x32` Wind / `0x33` Track / `0x37` User Configuration).
   FE-C writes are rate-limited to **~4 Hz** with latest-wins coalescing so interval engines cannot flood the UART.
   **Deferred:** Tacx NEO Road Feel / isokinetic (`0xFC` — needs Garmin package; out of scope).
5. Else error: unsupported device (GATT summary included).

### Trainer inventory (FTMS vs FE-C-only)

On every live connect the core prints a GATT table, for example:

```text
GATT inventory (N) — class=ftms
UUID    Name    Properties
0x2ad2  Indoor Bike Data    notify
0x2ad9  FTMS Control Point  indicate|write
…
```

Use one FTMS trainer and one legacy FE-C-only Tacx to fill your lab matrix. Dual trainers prefer FTMS. No private Garmin Tacx APIs are used.

### Disconnect + reconnect during intervals

- When the BLE notification stream ends (trainer asleep / out of range / other app), connection state becomes **Error** with “Link lost — tap Reconnect…”.
- **Reconnect** keeps an active interval preset and restores the current phase ERG target (or last manual ERG watts) after the link is back.
- Quit other apps first; exclusive control still applies after reconnect.

### Demo mode

- Demo is **on** by default (header toggle). Scan returns stub devices; metrics tick locally; ERG / resistance / intervals work without BLE.
- Turn Demo **off** for live FTMS → FE-C fallback. The red **DEMO** badge is shown whenever demo is active.

## CI

GitHub Actions (`.github/workflows/ci.yml`):

| Job | What |
| --- | --- |
| **Rust** | `cargo test` in `rust/` |
| **Flutter** | `flutter pub get`, `flutter analyze`, `flutter test`, Linux desktop deps as needed |

## Protocol context

| Interface | Role in this app |
| --- | --- |
| **FTMS** (BLE) | Primary control + feedback |
| **Tacx FE-C over BLE** | Fallback for older Tacx without FTMS |
| ANT+ FE-C (radio) | Out of scope |
| Private Tacx extras | Out of scope |

## Non-goals

- Connect IQ / Garmin watch remotes  
- Private Tacx Road Feel / virtual gear  
- FIT recording / ANT+ USB sticks  
- Multi-trainer simultaneous control  

## Tests

```bash
cd rust && cargo test
flutter analyze
flutter test
```

## License

MIT
