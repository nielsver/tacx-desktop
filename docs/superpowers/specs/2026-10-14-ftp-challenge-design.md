# FTP Challenge and Wahoo TICKR Design

**Status:** Awaiting user review  
**Date:** 2026-10-14

## Goal

Extend Tacx Desktop with a guided FTP assessment that uses live trainer power and can display heart rate from a Wahoo TICKR BLE monitor. Refresh the ride experience into a clear, polished training dashboard that works on Windows and Linux, while retaining the app's existing macOS support.

## Current application

The app uses a Flutter desktop dashboard and a Rust core connected through `flutter_rust_bridge`. Rust uses `btleplug` for BLE scanning and currently manages one trainer connection. It supports FTMS trainers and Tacx FE-C-over-BLE trainers, live power/cadence/speed metrics, ERG, resistance, intervals, simulation, and a simulated demo trainer. The dashboard is concentrated in `lib/src/ui/ride_dashboard.dart`; trainer-facing Rust APIs are in `rust/src/api/trainer.rs` and the controller is in `rust/src/trainer/controller.rs`.

There is no heart-rate service, sensor connection, FTP assessment, or persisted ride history today. Existing BLE support already targets Windows, Linux/BlueZ, and macOS.

## User experience

### Training dashboard

Refresh the dashboard as a focused training console with a dark, low-glare surface, restrained high-contrast accent colors, clear typography, and large readable live metrics. Keep trainer connection and control actions discoverable, and give the FTP challenge its own focused view so a rider can read power, heart rate, cadence, and remaining time at a glance. Retain the existing ERG, resistance, interval, and simulation capabilities.

Show trainer and heart-rate monitor as separate connection statuses. Heart rate is optional for trainer control and for the FTP test; if no monitor is connected, the challenge continues and the heart-rate area explains that a sensor can be connected for live HR.

### FTP challenge

The challenge is a one-session guided assessment:

1. Confirm that a trainer is connected; allow a heart-rate monitor to be connected optionally.
2. Run a timed 10-minute warm-up with phase prompts, using free-ride trainer behavior and no ERG targets.
3. Run a 20-minute maximal sustainable effort. Do not apply ERG targets during this phase, so trainer control does not dictate the rider's effort.
4. Calculate estimated FTP as 95% of the arithmetic mean trainer power recorded over the complete 20-minute effort. Show the estimate, average power, and test duration in the result view.

Display live power and elapsed/remaining time throughout both phases, along with cadence and heart rate when available. Include pause, resume, and end controls. Paused time does not count toward either phase. Ending before all 20 active effort minutes produces no FTP estimate; completing the effort produces an estimate. The initial version keeps the result in the current app session and does not create a saved history or change the user's FTP setting.

The app must make clear that this is an estimated FTP from a 20-minute test. It is a training feature, not medical advice. Demo mode must be able to exercise the screen and calculation without BLE hardware.

## Architecture and data flow

Add an independent BLE heart-rate monitor session in the Rust trainer core, alongside the existing trainer session. Scan for the standard Heart Rate Service (`0x180D`), subscribe to Heart Rate Measurement (`0x2A37`), and parse the BLE flags to support both 8-bit and 16-bit heart-rate values. Use the standard BLE protocol supported by the Wahoo TICKR; do not add a Wahoo-specific SDK or service dependency.

Keep trainer control and sensor connection lifecycles separate so connecting or disconnecting the TICKR cannot disconnect, replace, or take control of the trainer. Expose sensor scan/connect/disconnect and a heart-rate snapshot through the Rust API and regenerated Flutter bridge. Track the last sample time so the UI can mark a lost or stale signal instead of presenting an old value as current. Reject malformed measurement packets without crashing the notification stream.

Implement challenge timing and power aggregation as a small independently testable domain component. The UI starts/stops/pauses/resumes its phases and polls the trainer metrics already provided by Rust. Collect power only during the 20-minute effort and weight each reading by the elapsed active time since the prior reading, so a missed UI frame does not duplicate or overweight a reading. A trainer disconnect pauses the active phase and retains the effort time and samples; after reconnection, require the rider to explicitly resume. The demo metrics path supplies deterministic simulated power and heart rate for exercising the flow.

The connection path continues to use `btleplug` on each desktop platform. Windows uses its existing BLE backend, Linux uses BlueZ and the user's D-Bus session, and macOS retains the existing Bluetooth permission setup. A TICKR and trainer require two concurrent BLE peripheral connections; adapter or OS limits and unavailable peripherals must produce a visible, actionable error while leaving the other connection intact.

## Failure and recovery behavior

- Sensor scan/connect failure is reported separately from trainer connection state.
- A sensor disconnect or stale notification clears the current live HR value and shows a reconnect action; the ride and FTP challenge continue.
- A trainer disconnect during an active assessment pauses the challenge clock and marks the test as interrupted. Reconnection requires an explicit user resume; if the assessment is ended instead, no FTP estimate is produced.
- Power samples must be finite and non-negative. If no usable samples were recorded during the 20-minute effort, do not calculate an FTP result.
- Demo mode must clearly mark simulated readings and must not require BLE hardware.

## Cross-platform requirements

The experience and BLE feature must work in the existing Windows and Linux desktop builds. Preserve macOS build compatibility. Document BlueZ/D-Bus prerequisites and the normal-user permission model. Do not promise support for every Linux distribution package format; retain the repository's portable Flutter bundle/source-build support model.

## Out of scope

- ANT+ heart-rate sensors or ANT+ trainer control.
- Wahoo cloud accounts, proprietary Wahoo APIs, or firmware operations.
- FIT export, cloud sync, user accounts, saved test history, or automatic FTP profile updates.
- Changing the existing trainer protocols or adding simultaneous trainer control.
- Native installers for every Linux distribution.

## Acceptance criteria

1. A user can scan and connect to a standard BLE heart-rate monitor such as a Wahoo TICKR while the trainer remains connected and controllable.
2. Heart-rate measurement parsing handles both BLE value widths and malformed packets safely.
3. The dashboard reports sensor connection and stale/lost HR independently of trainer status.
4. A timed 10-minute warm-up and 20-minute free-ride effort can be started, paused, resumed, and ended; paused time does not count, and ERG is not applied during the test.
5. Completing the effort calculates `estimated FTP = round(0.95 × average power during the effort)` and presents the result; ending early does not present a completed FTP estimate.
6. The same challenge can be exercised in demo mode with simulated trainer power and heart rate.
7. Windows and Linux builds retain the existing trainer functionality and can manage the trainer and TICKR concurrently; macOS remains build-compatible.
8. The refreshed dashboard remains readable at common desktop sizes and retains the current trainer controls.
