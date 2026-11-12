# FTP Challenge and Wahoo TICKR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add concurrent BLE heart-rate support for Wahoo TICKR, a guided FTP assessment, and a polished cross-platform training dashboard.

**Architecture:** Keep trainer control in its current Rust controller and add a separate heart-rate monitor controller so either BLE peripheral can be managed without replacing the other. Parse HR packets in a small Rust module, expose an independent snapshot/API over flutter_rust_bridge, and implement FTP timing and power aggregation in a pure Dart domain object consumed by a focused challenge screen.

**Tech Stack:** Flutter/Dart 3.9, Rust 2021, btleplug 0.13, Tokio, flutter_rust_bridge 2.13, Flutter Material 3.

**Spec:** `docs/superpowers/specs/2026-10-14-ftp-challenge-design.md`

## Global Constraints

- Keep `btleplug = "0.13"`, `uuid = "=1.26.1"`, and `flutter_rust_bridge = "=2.13.0"` unchanged.
- Support concurrent trainer and heart-rate BLE peripherals on Windows and Linux; preserve macOS build compatibility.
- Use BLE Heart Rate Service `0x180D` and Measurement characteristic `0x2A37`; add no Wahoo-specific SDK.
- FTP assessment uses a 10-minute timed warm-up and 20 active minutes of free-ride effort; never apply ERG targets during challenge phases.
- Estimated FTP is `round(0.95 × arithmetic mean power across the effort)`; do not produce an estimate on early end.
- HR is optional, sensor loss must not stop a challenge, and demo mode needs simulated power and HR.
- Keep existing trainer controls and current-session-only FTP results; add no user profile, cloud sync, or saved history.

## Review Focus

- Malformed or truncated BLE Heart Rate Measurement packets return no sample and never panic the notification task. (Task 1 parser cases.)
- A missing/disconnected/stale HR peripheral does not disconnect the trainer or pause the FTP test. (Task 2 independent lifecycle cases and Task 4 UI flow.)
- Pause time is excluded from phase durations and weighted power averaging; early end cannot show a result. (Task 3 state and accumulator cases.)
- Trainer link loss pauses the active challenge; after reconnect the rider must explicitly resume. (Task 3 interruption cases and Task 4 UI flow.)
- The dashboard remains usable at compact desktop widths and preserves the existing trainer actions. (Task 5 responsive widget cases.)

---

### Task 1: Heart-rate value model and packet parser

**Files:**
- Create: `rust/src/trainer/heart_rate.rs`
- Modify: `rust/src/trainer/mod.rs`
- Modify: `rust/src/trainer/types.rs`
- Test: inline unit tests in `rust/src/trainer/heart_rate.rs`

**Interfaces:**
- Produces `parse_heart_rate_measurement(data: &[u8]) -> Option<u16>`.
- Produces FRB-exposed `HeartRateSnapshot { connected: bool, device_name: String, bpm: Option<u16>, sample_age_ms: Option<u64>, detail: String, is_demo: bool }`.
- Heart Rate Measurement flags bit 0 selects 8-bit vs 16-bit unsigned little-endian BPM. Bytes after the value are optional energy/RR data and need not be consumed to return BPM.

- [ ] **Step 1: Add parser tests first**

```rust
#[test]
fn parses_eight_bit_and_sixteen_bit_measurements() {
    assert_eq!(parse_heart_rate_measurement(&[0x00, 72]), Some(72));
    assert_eq!(parse_heart_rate_measurement(&[0x01, 0x2c, 0x01]), Some(300));
}

#[test]
fn rejects_truncated_measurements_and_accepts_optional_trailing_fields() {
    assert_eq!(parse_heart_rate_measurement(&[]), None);
    assert_eq!(parse_heart_rate_measurement(&[0x00]), None);
    assert_eq!(parse_heart_rate_measurement(&[0x01, 0x2c]), None);
    assert_eq!(parse_heart_rate_measurement(&[0x00, 72, 0x02, 0x00]), Some(72));
}
```

- [ ] **Step 2: Run the focused Rust tests and confirm the parser tests fail before implementation**

Run: `cargo test --manifest-path rust/Cargo.toml heart_rate::tests -- --nocapture`  
Expected: compile failure because the parser/module does not exist yet.

- [ ] **Step 3: Implement the parser and snapshot type**

Create `heart_rate.rs`; check the flags byte and required length before indexing, decode 8-bit or little-endian 16-bit BPM, and ignore trailing fields. Add the module declaration and the public snapshot struct. Keep parser behavior pure, synchronous, and independent from BLE types.

- [ ] **Step 4: Run the focused Rust tests**

Run: `cargo test --manifest-path rust/Cargo.toml heart_rate::tests -- --nocapture`  
Expected: both parser tests pass.

- [ ] **Step 5: Commit the parser/model change**

```bash
git add rust/src/trainer/heart_rate.rs rust/src/trainer/mod.rs rust/src/trainer/types.rs
git commit -m "feat: parse BLE heart rate measurements"
```

### Task 2: Independent BLE sensor lifecycle and Flutter bridge

**Files:**
- Create: `rust/src/trainer/heart_rate_monitor.rs`
- Modify: `rust/src/trainer/mod.rs`
- Modify: `rust/src/api/trainer.rs`
- Modify: `rust/src/trainer/controller.rs` only where sharing BLE helpers is necessary
- Regenerate: `lib/src/rust/api/trainer.dart`, `lib/src/rust/trainer/types.dart`, and generated FRB files with `scripts/gen_bridge.sh`
- Test: Rust unit tests in `rust/src/trainer/heart_rate_monitor.rs`; Dart bridge API signatures generated by FRB

**Interfaces:**
- Produces `scan_heart_rate_sensors(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String>`.
- Produces `connect_heart_rate_sensor(device_id: Option<String>) -> Result<(), String>`.
- Produces `disconnect_heart_rate_sensor() -> Result<(), String>`.
- Produces `get_heart_rate_snapshot() -> HeartRateSnapshot`.
- Use an independent `OnceCell<Arc<AsyncMutex<HeartRateMonitor>>>`; do not store HR `Peripheral` inside `TrainerController` or call trainer `disconnect` during sensor lifecycle operations.
- Dart API names after bridge generation: `scanHeartRateSensors`, `connectHeartRateSensor`, `disconnectHeartRateSensor`, `getHeartRateSnapshot`; scan results use `protocolHint: "heart_rate"`.
- A pure `HeartRateState` owns device name, BPM, last sample `Instant`, connection/demo flags, and detail text; methods are `record_measurement(data, now)`, `mark_disconnected()`, and `snapshot(now)` so lifecycle rules can be tested without a BLE adapter.

- [ ] **Step 1: Define monitor lifecycle tests**

Test a disconnected default snapshot, disconnected/stale snapshot clearing the BPM, and a fresh valid sample snapshot containing the parsed BPM and device name. Keep these tests against a monitor state object that does not need a physical adapter.

- [ ] **Step 2: Run focused lifecycle tests and confirm they fail**

Run: `cargo test --manifest-path rust/Cargo.toml heart_rate_monitor::tests -- --nocapture`  
Expected: compile failure until the monitor state/lifecycle exists.

- [ ] **Step 3: Implement the independent BLE monitor**

Create a fresh `Manager`/adapter in the monitor controller; scan with an empty `ScanFilter` and post-filter advertisements for service `0x180D`. On connect, rediscover the device, connect, discover GATT, subscribe to `0x2A37`, and spawn a notification task. Store current BPM, last-sample `Instant`, device name, demo flag, and peripheral. Snapshot reports `connected=false`, `bpm=None` when link is dead or the last HR sample is at least 5 seconds old. A malformed packet is ignored without ending the stream. Sensor failure updates only monitor state.

- [ ] **Step 4: Add API wrappers and demo behavior**

In `api/trainer.rs`, lock only the monitor singleton for HR operations. Make `set_demo_mode` update the monitor's demo source with the trainer's setting, and have demo trainer connect/disconnect wrappers update the demo sensor's connected state. In demo mode, return a deterministic reading that changes slowly between 115 and 145 BPM while the demo trainer is connected; clear it when demo trainer disconnects. Keep live BLE scan/connect/disconnect independent from trainer operations.

- [ ] **Step 5: Regenerate and inspect the Flutter bridge**

Run: `./scripts/gen_bridge.sh`  
Expected: Dart exposes the four heart-rate API functions and `HeartRateSnapshot`; generated signatures match the Rust wrappers without unrelated API changes.

- [ ] **Step 6: Run focused Rust and Flutter analysis checks**

Run: `cargo test --manifest-path rust/Cargo.toml heart_rate_monitor::tests -- --nocapture`  
Run: `flutter analyze`  
Expected: monitor lifecycle tests pass and Dart/Rust bridge types analyze without errors.

- [ ] **Step 7: Commit the independent monitor and bridge**

```bash
git add rust/src/trainer rust/src/api/trainer.rs lib/src/rust
git commit -m "feat: connect BLE heart rate monitors independently"
```

### Task 3: FTP challenge state machine and power calculation

**Files:**
- Create: `lib/src/challenge/ftp_challenge.dart`
- Create: `test/ftp_challenge_test.dart`

**Interfaces:**
- `enum FtpChallengePhase { idle, warmup, effort, pausedWarmup, pausedEffort, completed, ended, interrupted }`.
- `FtpChallengeSnapshot` fields are `phase`, `phaseElapsed`, `phaseRemaining`, `effortElapsed`, nullable `averagePowerW`, nullable `estimatedFtpW`, and `statusLabel`.
- `FtpChallenge.start(now)`, `pause(now)`, `resume(now)`, `end(now)`, `interrupt(now)`, and `tick(now, {required double? powerW})` update an in-memory challenge; constructor accepts configurable durations for fast deterministic tests and defaults to 10 and 20 minutes.
- Power accumulator weights each valid sample by elapsed active time since the preceding sample. Only finite non-negative samples in the effort phase count. Completed FTP rounds `0.95 × weighted mean watts` to the nearest integer.

- [ ] **Step 1: Add failing state-machine tests**

```dart
test('completes warmup then calculates FTP from effort power', () {
  final c = FtpChallenge(warmupDuration: const Duration(seconds: 2), effortDuration: const Duration(seconds: 4));
  final t0 = DateTime.utc(2026, 1, 1);
  c.start(t0);
  c.tick(t0.add(const Duration(seconds: 1)), powerW: 20);
  c.tick(t0.add(const Duration(seconds: 2)), powerW: 200);
  expect(c.snapshot.phase, FtpChallengePhase.effort);
  c.tick(t0.add(const Duration(seconds: 3)), powerW: 200);
  c.tick(t0.add(const Duration(seconds: 4)), powerW: 200);
  c.tick(t0.add(const Duration(seconds: 5)), powerW: 200);
  c.tick(t0.add(const Duration(seconds: 6)), powerW: 200);
  expect(c.snapshot.phase, FtpChallengePhase.completed);
  expect(c.snapshot.estimatedFtpW, 190);
});

test('paused time is excluded and ending early has no estimate', () {
  final c = FtpChallenge(warmupDuration: const Duration(seconds: 1), effortDuration: const Duration(seconds: 4));
  final t0 = DateTime.utc(2026, 1, 1);
  c.start(t0);
  c.tick(t0.add(const Duration(seconds: 1)), powerW: 200);
  c.tick(t0.add(const Duration(seconds: 2)), powerW: 200);
  c.pause(t0.add(const Duration(seconds: 2)));
  c.resume(t0.add(const Duration(seconds: 7)));
  c.end(t0.add(const Duration(seconds: 8)));
  expect(c.snapshot.effortElapsed, const Duration(seconds: 2));
  expect(c.snapshot.estimatedFtpW, isNull);
});
```

- [ ] **Step 2: Run the focused Dart tests and confirm they fail**

Run: `flutter test test/ftp_challenge_test.dart`  
Expected: failure because `FtpChallenge` and its snapshot do not exist.

- [ ] **Step 3: Implement the pure challenge model**

Implement phase transitions using the injected `DateTime` values, excluding paused/interrupted intervals. Warm-up and effort phase time must be based on actual phase transition times even if a UI tick arrives after a boundary. When warm-up expires, begin effort and reset the previous-power timestamp so warm-up watts never contribute. At the first valid effort reading, establish an accumulator baseline; on later ticks accumulate the previous valid watts over elapsed active effort time. Ignore an interval if its prior reading is invalid. At effort completion compute weighted mean over covered sample time and round `0.95 × mean`; set no estimate when ended before full effort duration or when no valid effort power was accumulated. Store the resume phase when trainer loss interrupts the challenge; user resume continues that phase.

- [ ] **Step 4: Complete edge-case tests and rerun the focused suite**

Add explicit assertions for pause/resume duration, interruption/resume, early end, zero power, invalid negative/NaN power, completion with no valid samples, and a delayed UI tick that crosses the warm-up boundary. Run `flutter test test/ftp_challenge_test.dart`; expected all cases pass.

- [ ] **Step 5: Commit challenge logic**

```bash
git add lib/src/challenge/ftp_challenge.dart test/ftp_challenge_test.dart
git commit -m "feat: model guided FTP challenge"
```

### Task 4: Challenge screen and independent sensor controls

**Files:**
- Create: `lib/src/ui/ftp_challenge_screen.dart`
- Modify: `lib/src/ui/ride_dashboard.dart`
- Test: `test/ftp_challenge_screen_test.dart`

**Interfaces:**
- Dashboard adds an FTP Challenge entry point and an independent Heart Rate card with scan, select, connect, disconnect, stale/lost, reconnect, and demo states.
- `FtpChallengeScreen` owns one `FtpChallenge`, polls the existing trainer metrics/connection APIs and Task 2 heart-rate snapshot API, and starts/stops its own 250 ms UI timer while mounted.
- Dashboard adds a `Navigator` route to `FtpChallengeScreen`; HR scan/connect/disconnect stays in the dashboard sensor card and is not part of the route's lifecycle.
- During warm-up/effort, stop any running interval and prevent ERG/resistance controls from issuing commands. Before allowing effort start, ensure an active interval cannot continue sending power targets. On a trainer error/disconnect, call `interrupt`; require explicit resume after trainer reconnection.

- [ ] **Step 1: Add widget tests for the essential states**

Cover challenge entry in demo mode, heart-rate sensor absent while challenge remains available, active screen values, stale HR state, pause/resume/end controls, and interrupted state after trainer loss. Assert no completed result appears after early end.

- [ ] **Step 2: Run the focused widget tests and confirm they fail**

Run: `flutter test test/ftp_challenge_screen_test.dart`  
Expected: failure because the new challenge screen and dashboard entry point do not exist.

- [ ] **Step 3: Implement the focused FTP screen**

Create a dedicated route with a strong live power number, large phase timer/progress, compact HR/cadence metrics, and clear Start/Pause/Resume/End actions. Before warm-up, stop active intervals and command 0% resistance to put the trainer in neutral manual/free-ride mode; if that command fails, do not start and show the trainer error. Warm-up uses short coaching prompts and no ERG target; effort uses no trainer target updates. On each app tick, provide the current trainer power only while the challenge is in effort. Read heart-rate snapshots independently and display no stale numeric BPM when the snapshot is stale. Show the FTP estimate, average watts, and duration only after completion.

- [ ] **Step 4: Wire the dashboard's heart-rate controls**

Add separate scan/list/connect/disconnect controls using the generated bridge API. Preserve the trainer connection selector and disconnect behavior. Poll the HR snapshot separately; show device name, live BPM, and stale/disconnected explanation. Sensor errors must not set the trainer `_error`/connection state or block challenge actions.

- [ ] **Step 5: Run focused widget and challenge checks**

Run: `flutter test test/ftp_challenge_screen_test.dart test/ftp_challenge_test.dart`  
Expected: challenge screen and state-machine scenarios pass.

- [ ] **Step 6: Commit the FTP experience and sensor controls**

```bash
git add lib/src/ui/ftp_challenge_screen.dart lib/src/ui/ride_dashboard.dart test/ftp_challenge_screen_test.dart
git commit -m "feat: add guided FTP challenge screen"
```

### Task 5: Visual refresh, responsive layout, and platform guidance

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/src/ui/ride_dashboard.dart`
- Modify: `lib/src/ui/ftp_challenge_screen.dart`
- Modify: `test/widget_test.dart`
- Modify: `README.md`

**Interfaces:**
- Retain existing ERG, resistance, interval, and simulation controls while improving visual hierarchy and compact-width layout.
- Shared theme uses dark low-glare surfaces, high-contrast cyan/blue plus restrained lime accent, consistent spacing, readable typography, and status colors that do not rely on color alone.
- README explains TICKR pairing/connection, two simultaneous BLE links, Windows unpaired-device guidance, and Linux BlueZ/D-Bus prerequisites.

- [ ] **Step 1: Add responsive dashboard widget assertions**

Update the dashboard widget test to verify the new sensor and challenge entry points while retaining ERG, Resistance, Intervals, Simulation, DEMO, and Reconnect. Run it at the existing 1400×900 size and the known-overflow 800×600 compact size and assert no Flutter overflow exception.

- [ ] **Step 2: Run the widget test and confirm the compact layout case fails before the layout change**

Run: `flutter test test/widget_test.dart`  
Expected: existing wide case passes; new compact-size assertion exposes the current dashboard overflow.

- [ ] **Step 3: Refine theme and responsive layout**

Update `main.dart` Material 3 theme tokens and ride dashboard layout. Keep metrics large and glanceable, separate connection states, group secondary controls, and switch from three equal side-by-side control panels to a scrollable/wrapped layout below a desktop breakpoint. Ensure buttons and labels remain available at compact widths. Apply the same color, spacing, and typography rules to the challenge route.

- [ ] **Step 4: Update Windows/Linux/macOS instructions**

Add a Wahoo TICKR section to README: wake the TICKR, scan/connect inside Tacx Desktop, and explain that trainer and HR monitor stay independently connected. Preserve the existing instruction to leave the trainer unpaired in Windows OS Settings. Extend the platform table with BLE HR support and keep BlueZ/D-Bus permission notes for Linux; retain macOS permission notes.

- [ ] **Step 5: Run focused Flutter checks and inspect the diff**

Run: `flutter test test/widget_test.dart test/ftp_challenge_screen_test.dart test/ftp_challenge_test.dart`  
Run: `flutter analyze`  
Expected: responsive dashboard and challenge screens render without overflow, assertions pass, and analyzer reports no errors.

- [ ] **Step 6: Commit responsive UI and platform docs**

```bash
git add lib/main.dart lib/src/ui/ride_dashboard.dart lib/src/ui/ftp_challenge_screen.dart test/widget_test.dart README.md
git commit -m "design: refresh cross-platform training dashboard"
```

### Task 6: End-to-end build and documentation consistency

**Files:**
- Modify if needed: `README.md`
- No new production files expected.

**Interfaces:**
- Confirm generated bridge matches Rust API, demo sensor follows demo mode, and platform instructions describe supported build/runtime prerequisites accurately.

- [ ] **Step 1: Run the project verification commands**

Run: `cargo test --manifest-path rust/Cargo.toml`  
Run: `flutter analyze`  
Run: `flutter test`  
Expected: all Rust and Flutter checks pass.

- [ ] **Step 2: Build each available desktop target**

Run on the corresponding supported host/toolchain: `flutter build windows --release`, `flutter build linux --release`, and `flutter build macos --release`. Expected: each available target compiles; report unavailable host toolchains separately from code failures.

- [ ] **Step 3: Review final diff and commit any documentation correction**

Run: `git diff --check` and `git status --short`. Confirm no generated bridge drift, no unrelated files, and README claims match implemented behavior.

### Spec coverage check

- Independent TICKR lifecycle, packet parsing, stale signal handling, and concurrent connection: Tasks 1–2.
- Demo heart rate and deterministic simulation: Task 2.
- 10-minute warm-up, 20-minute effort, pauses, interruptions, power aggregation, FTP result/early end: Task 3.
- Focused challenge experience, optional HR, sensor loss behavior, trainer disconnect flow: Task 4.
- Polished responsive dashboard and preserved trainer controls: Task 5.
- Windows/Linux/macOS bridge/build/documentation compatibility: Tasks 2, 5, and 6.

### Plan self-review

- **Spec coverage:** Every acceptance criterion maps to one or more tasks above.
- **Placeholder scan:** No TBD/TODO placeholders remain; code examples and command expectations are explicit.
- **Type consistency:** Rust snapshots and generated APIs are named consistently; Dart challenge phases and snapshot fields are defined in Task 3 before UI consumption in Task 4.
- **Review focus:** Each of the five likely failure modes has a corresponding parser, lifecycle, state, widget, or compact-layout test case.
