# Tacx Desktop

Cross-platform **desktop** remote for Tacx (and other) smart trainers.

**Stack:** Flutter UI + Rust trainer core (`btleplug`) via [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/).

> **Note:** The earlier Python / CustomTkinter / Bleak scaffold lived here as v0. It was replaced by this Flutter + Rust app. See [`archive/python-v0/`](archive/python-v0/) for the historical code.

Not a Connect IQ / watch app. Not private Tacx Road Feel. Not ANT+ radio (FE-C here is **over BLE**, Tacx UART).

## Features

| Feature | Demo mode | Real trainer |
| --- | --- | --- |
| Scan / connect | Stub devices | Live BLE |
| Auto protocol | Demo | **FTMS first** (Tacx + **Wahoo Kickr** / Kickr Core / Bike), then **Tacx FE-C-over-BLE** fallback |
| Live power, cadence, speed | Simulated | FTMS Indoor Bike Data / FE-C pages 16+25 |
| ERG target watts (± 5 / 10 / 25) | Yes | FTMS Control Point or FE-C target power |
| Resistance % | Yes | FTMS Supported Resistance Level Range + Set Resistance; FE-C basic resistance 0–200 N mapped from % |
| Interval presets (10×30/30, 5×3/2, 4×4/3) | Yes | Yes |
| Exclusive-control messaging | Hint banner | Clear errors for busy trainer / NOCTRL |
| FTMS Control Point indications | — | Parsed (`0x80`); NOCTRL / failures surface in UI |
| GATT inventory on connect | — | UUID/property table + FTMS vs FE-C class in logs |
| Link-lost → auto-reconnect | Simulated disconnect N/A | Backoff 1/3/8/15 s, restores ERG/resistance/grade; then manual Reconnect |
| FE-C write rate limit | — | ~4 Hz latest-wins coalesce on UART WithoutResponse |
| FE-C Track / Wind / User-config | Demo simulates grade | Pages `0x33` / `0x32` / `0x37` + Flutter Simulation panel |
| FTMS Indoor Bike Simulation | Demo grade feel | Opcode `0x11` + Crr/Cw sliders when Feature bit 13 set |
| Fitness Machine Status | — | Subscribe `0x2ADA`; stop/pause banner; control-lost → Error |
| Heart rate (relayed) | Simulated strap | FTMS Indoor Bike Data HR field (flag bit 9) or FE-C page 16 byte 6 — shown as a card when present, averaged in ride totals, written to TCX (`HeartRateBpm`) |
| Heart-rate strap (BLE) | Real BLE only | Separate chest strap over the standard Heart Rate Service (0x180D / 0x2A37: Garmin HRM-Dual/Pro, Polar H9/H10, Wahoo TICKR…) — **Find HR strap → Connect strap** in the bar under the ride totals; runs beside the trainer link, overrides trainer-relayed HR while fresh (< 5 s), so the card, ride avg/max and TCX use the strap |
| Ride totals | Yes | 1 Hz sampler while connected: ride time, avg/max power, avg cadence, kJ, distance; reconnect gaps paused; Reset |
| Ride export (TCX) | Yes | **Save TCX** writes `~/Documents/Tacx Desktop/tacx-ride-<UTC>.tcx` (1 s trackpoints: power, cadence, speed, distance, heart rate when relayed; validated against Garmin's TCX v2 + ActivityExtension v2 XSDs) — upload to Garmin Connect, Strava, intervals.icu |
| DEMO badge | Always when demo on | — |

## Platforms

| OS | Status | Notes |
| --- | --- | --- |
| **Linux (Garuda / Arch primary)** | **Primary perfect-working target** | **BlueZ** + D-Bus; Release `tacx-desktop-linux-x64` tar.gz; see [Garuda / Linux first-run](#garuda--linux-first-run-released-binary) |
| **Windows** | Supported | WinRT BLE; leave trainer **unpaired** in OS Settings |
| **macOS** | Supported | TCC Bluetooth; entitlements included (not notarized in CI) |

Portable Linux binary works on BlueZ distros (Garuda, Arch, Fedora, Debian/Ubuntu). We do not ship every distro’s native `.deb`/`.rpm`.



## First-run checklist (`flutter doctor`)

Run `flutter doctor -v` after installing the toolchain. You want these green before `flutter run`:

| Check | Windows | Linux | macOS |
| --- | --- | --- | --- |
| Flutter / Dart SDK | 3.29+ stable | same | same |
| Visual Studio | **Desktop development with C++** workload (MSVC, Windows SDK, CMake) | — | — |
| Linux toolchain | — | `clang`, `cmake`, `ninja-build`, `pkg-config`, GTK 3.0 dev (`libgtk-3-dev`) | — |
| Xcode | — | — | Xcode + CocoaPods as Flutter asks |
| Chrome / network | optional | optional | optional |
| Rust | `rustup` stable (`rustc --version`) | same | same |
| Bluetooth | Adapter on; **trainer unpaired** in OS Settings | BlueZ + user session / `bluetooth` group | TCC Bluetooth allow for the app |

**Demo-first path:** `flutter pub get` → `flutter run -d windows` (or `linux` / `macos`) → leave **DEMO** on → exercise ERG / Resistance / Intervals / Simulation. Then Demo **off** for live BLE (quit other apps; Windows: forget OS pairing).

**Release without a local toolchain:** GitHub Actions → **Release** → *Run workflow* (manual) builds `tacx-desktop-windows-x64` (zip), `tacx-desktop-linux-x64` (tar.gz) and `tacx-desktop-macos` (zipped `.app`, ad-hoc signed, not notarized) artifacts; a `v*` tag also attaches all three to a GitHub Release. Local: `./scripts/build_release.sh linux` (Garuda primary) or `windows` / `macos`.


## Garuda / Linux first-run (released binary)

**Primary target.** Download Actions → **Release** → artifact `tacx-desktop-linux-x64` (or a GitHub Release `tacx-desktop-linux-x64-v*.tar.gz`).

```bash
# BlueZ + runtime (Garuda / Arch)
sudo pacman -S --needed bluez bluez-utils gtk3 libepoxy xz util-linux
sudo systemctl enable --now bluetooth
groups | grep -q bluetooth || { sudo usermod -aG bluetooth "$USER"; echo "Log out/in"; }

mkdir -p ~/Apps && tar -xzf tacx-desktop-linux-x64-*.tar.gz -C ~/Apps
cd ~/Apps/tacx-desktop
chmod +x ./tacx_desktop
ls lib | grep -i tacx_desktop_core    # must list the Rust cdylib
ldd ./tacx_desktop | grep 'not found' || echo "ldd OK"

# Run from the bundle dir so RPATH $ORIGIN/lib resolves libtacx_desktop_core
./tacx_desktop
# Optional: "Tacx Desktop" in the KDE/GNOME app menu (user-only, ~/.local); undo with ./uninstall.sh
./install.sh
# LD_LIBRARY_PATH fallback only if needed:
#   export LD_LIBRARY_PATH="$PWD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Wayland blank/crash: GDK_BACKEND=x11 ./tacx_desktop
```

The tarball includes `FIRST_RUN.txt`. Full smoke: `./scripts/garuda_first_run_smoke.sh ~/Downloads/tacx-desktop-linux-x64-*.tar.gz`.

**In app:** Demo ON → smoke UI (includes DEMO KICKR CORE) → Demo OFF → quit Zwift/Tacx/MyWhoosh/Wahoo → forget trainer in KDE BT → Scan (Tacx **or Kickr**) → Connect → ERG. Manual Connect must **not** freeze the UI (spinner/busy only).

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

### Linux (BlueZ) — Garuda / Arch

```bash
sudo pacman -S --needed bluez bluez-utils bluez-libs gtk3 libepoxy xz util-linux
sudo systemctl enable --now bluetooth
# Debian/Ubuntu: sudo apt install bluez bluetooth libgtk-3-0 …
sudo usermod -aG bluetooth "$USER"   # then log out/in
rfkill unblock bluetooth 2>/dev/null || true
bluetoothctl power on
# D-Bus session must be active (Plasma/SDDM login — not a raw tty without session bus)
```

- Run as a **normal user** (**never `sudo`** the app).
- Keep the scan filter **empty** (this app post-filters by FTMS UUID / Tacx-like names). BlueZ UUID filters are unioned across D-Bus clients and can hide FE-C-only trainers.
- **Forget OS pairing** in KDE/Plasma Bluetooth — connect **only** in-app.
- Automated checks: `./scripts/garuda_first_run_smoke.sh [tar.gz]`

### Wahoo Kickr (FTMS)

Same **public FTMS** control path as Tacx (`0x1826` Indoor Bike Data `0x2AD2` + Control Point `0x2AD9`). Recognized in scan by FTMS UUID, name (`KICKR` / `Wahoo`), or manufacturer company ID `0x0131`. Demo includes **DEMO KICKR CORE (FTMS)**.

| Topic | Behaviour |
| --- | --- |
| Proprietary Wahoo GATT (`a026*`, legacy CP) | **Out of scope** — ignored; public FTMS only |
| ERG | Target Power opcode; **Kickr often needs 3–5 s to settle** (normal — UI toast/caption say so) |
| Resistance % | Enabled only when `0x2AD6` and/or Feature Target Resistance bit is present. **Kickr Bike** → Resistance panel disabled (use ERG / Simulation) |
| Simulation `0x11` | When Feature bit 13 set; honest disabled otherwise |
| Exclusive control | Quit **Wahoo app** / Zwift / MyWhoosh; one controller only. Busy/NOCTRL banners mention Wahoo |
| OS pairing | Garuda: forget in KDE BT. Windows: Remove device. Connect **only in-app**. Keep empty `ScanFilter` |

Hardware validation still needs Niels’ Kickr model + live GATT dump (Feature `0x2ACC`, Power `0x2AD8`, Resistance `0x2AD6` present/absent).

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


## Windows build, run & release

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

1. Scan advertisements (FTMS UUID, **Kickr/Wahoo** name or company ID `0x0131`, and/or Tacx-like names). Empty `ScanFilter` + post-filter (BlueZ-safe).
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

Report each trainer + OS combination with the **Trainer test report** issue template (Issues → New issue). It walks through scan, unpaired connect, ERG, resistance, simulation, intervals and the power-off drop test, and the `hardware-test` label collects the reports into the hardware matrix.

### Disconnect + reconnect during intervals

- When the BLE notification stream ends (trainer asleep / out of range), the app **auto-reconnects** with bounded backoff (~1 s, 3 s, 8 s, 15 s → 4 attempts). The dashboard shows “Connection lost — reconnecting (2/4) in 3 s…” with **Reconnect now** / **Disconnect**; the policy lives in `rust/src/trainer/reconnect.rs`.
- On success the previous target is restored — current interval-phase ERG watts (the preset keeps running through the drop), else last ERG watts / resistance % / simulation grade.
- After the last attempt it gives up and shows “Couldn't reconnect after 4 tries … tap Reconnect”; manual **Reconnect** restores the same target.
- No auto-retry after a user Disconnect, in demo mode, after a new manual connect, or when another app holds control (FTMS Control Permission Lost / Request Control rejected — NOCTRL message instead).
- Quit other apps first; exclusive control still applies after reconnect.

### Demo mode

- Demo is **on** by default (header toggle). Scan returns stub devices; metrics tick locally; ERG / resistance / intervals work without BLE.
- Turn Demo **off** for live FTMS → FE-C fallback. The red **DEMO** badge is shown whenever demo is active.

## CI

GitHub Actions (`.github/workflows/ci.yml`):

| Job / workflow | What |
| --- | --- |
| **Rust** (on push) | `cargo test` in `rust/` |
| **Flutter** (on push) | `flutter analyze` + `flutter test` (Linux; builds Rust cdylib) |
| **Linux launcher scripts** (on push) | `shellcheck` + `scripts/test_linux_install.sh` (install/uninstall in a temp `XDG_DATA_HOME`, `desktop-file-validate`) |
| **Release** (manual / `v*` tags) | Windows zip, Linux tar.gz (checks the Rust cdylib is bundled), macOS `.app` zip (checks Bluetooth entitlement + usage string) — not on every push |

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
