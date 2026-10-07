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
| DEMO badge | Always when demo on | — |

## Platforms

| OS | Status | Notes |
| --- | --- | --- |
| **Windows** | Supported | Bleak/btleplug WinRT BLE; build with Visual Studio + Flutter Windows desktop |
| **Linux** | Supported | Needs **BlueZ** + D-Bus; portable binary via `flutter build linux` |
| **macOS** | Supported | Enable **Bluetooth** permission for the app (entitlements included) |

“All distros” on Linux means: a portable Flutter Linux binary **or** `flutter run -d linux` / source build on common distros with BlueZ. We do not ship every distro’s native `.deb`/`.rpm` packager.

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
```

### macOS

- Allow Bluetooth for **Tacx Desktop** when prompted.
- Debug/Release entitlements request `com.apple.security.device.bluetooth`.

### Windows

- Windows 10/11 with BLE (built-in or USB dongle).
- Enable **Developer Mode** if Flutter asks; install Visual Studio C++ desktop workload for Windows builds.

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
# Linux portable bundle
flutter build linux --release
# → build/linux/x64/release/bundle/

# Windows
flutter build windows --release
# → build/windows/x64/runner/Release/

# macOS
flutter build macos --release
# → build/macos/Build/Products/Release/tacx_desktop.app
```

Ship the Linux `bundle/` folder as-is (includes `lib/` + binary). On Windows zip the `Release/` folder. On macOS distribute the `.app` (notarize for Gatekeeper if you ship outside your machine).

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

1. Scan advertisements (FTMS UUID and/or Tacx-like names).
2. Connect + discover GATT.
3. If FTMS Indoor Bike + Control Point → **FTMS** path (Request Control, Start/Resume, notify 0x2AD2).
4. Else if Tacx UART RX/TX (`6e40fec3…` / `6e40fec2…`) → **FE-C-over-BLE** path.
5. Else error: unsupported device.

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
