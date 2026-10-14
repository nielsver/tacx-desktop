# tacx-desktop: phone remote checklist (step 5)
*Refreshed 2026-10-14 (Brussels) against `main` @ `01564bc` (includes `f8832c6` effort API + `ride_events()`). Replaces the 8 Oct version (`3ac394f`). Read-only research. `docs/mobile-remote.md` is still the 8 Oct copy: Build should overwrite it with this file.*
*P0 = slice R1 (one cycle) · P1 = next · P2 = later. Roadmap: step 5 = remote, step 6 = race (same envelope; relay never accepts control).*

**Decision (unchanged):** Option A. The Rust core serves a single-file web page + WebSocket on one private LAN IPv4, port 47820, off by default, paired via QR. No app install, no accounts, no cloud, €0.
**Golden rule:** the remote is an overlay. A crash, disconnect or flood never touches trainer control, ERG/SIM or recording.

## 1. Audit of main (what exists today)
| Need | Current main | Status |
|---|---|---|
| Runtime | `controller.rs`: global `RUNTIME: OnceCell<Runtime>` (multi-thread), `runtime()` accessor; `ride_ticker` spawned on it | Exists: spawn the server on `runtime()` |
| tokio features | `rt-multi-thread, macros, sync, time`. **No `net`, no `io-util`** | Add `net` (axum needs it) |
| HTTP/WS deps | none (no axum/hyper/tungstenite). `getrandom 0.4.3` only transitive via `uuid` | Add explicitly |
| Effort API | `begin_effort(kind, demo)->u32`, `end_effort(completed)->Option<RideSlice>` (idempotent, emits one `RideEnded`), `current_effort()`, `effort_summary(id, ftp)`, `effort_stats(id)`, `export_effort_tcx(id, dir)`, `set_ride_paused(bool)` | Exists |
| Events | `ride_events(StreamSink<RideEvent>)`; `RideEventKind::RideEnded{slice_id}`; Dart already listens (summary/ghost/TCX) | Exists: remote end_save just calls `end_effort` |
| ERG / resistance / grade | `set_target_power(w)`, `set_resistance_percent(pct)`, `set_track_resistance(grade, crr)`; ranges via `get_power_range()`/`get_resistance_range()` | Exists |
| Live data | `get_metrics()`, `get_connection_snapshot()` (`is_demo`, mode), `get_workout_status()`, `get_route_status()`, `effort_stats` | Exists |
| Workout pause / resume / skip / next step | `workouts.rs` runs an absolute schedule from `t0`; no pause/skip; `WorkoutStatus` has no `next_*` | **Net-new** (P1; ride pause already exists) |
| QR in Flutter | `pubspec.yaml` has no `qr*` package | Render SVG in Rust, no new Dart dep |

## 2. Crate choice (measured)
Scratch projects with the same tokio line; `cargo tree -e normal`, unique crates:
| Option | Crates | Added vs tokio-only (10) | Notes |
|---|---|---|---|
| tiny_http 0.12 + tungstenite 0.28 | 42 | +32 | Blocking threads, not tokio; manual WS upgrade glue. Smallest, but awkward next to FRB/tokio |
| hyper 1 + hyper-util + tokio-tungstenite 0.28 | 55 | +45 | Hand-rolled routing/upgrade (~150 lines) |
| **axum 0.8** (`default-features=false, ["tokio","http1","ws"]`) | 71 | **+61** | Routing, `WebSocketUpgrade`, extractors; same stack as the step-6 relay |
| warp 0.4 (`server, websocket`) | 92 | +82 | Heaviest, slower-moving |
| `qrcode 0.14` (no default features, `svg`) + `if-addrs 0.13` + `subtle 2` | +4 | | Tiny |
- [ ] **P0 · Use axum 0.8 lean features.** +16 crates over raw hyper buys ergonomics and one codebase shared with the race relay. Add tokio `net`. All MIT/Apache.
- [ ] **P0 · Embed the page with `include_str!("remote/index.html")`**, not `rust-embed` (zero deps; one file).
- [ ] **P0 · QR in Rust:** `remote_pair() -> PairInfo{url, qr_svg, expires_ms}`; `pubspec` has no `flutter_svg`, so also return the module grid (`qr_modules: Vec<bool>, qr_width`) and draw it with a `CustomPainter`. No new Dart dep, and no `image` crate. The SVG is still used for the web page. Tokens: `getrandom` (direct dep, already in the lock).

## 3. Security (kept from 8 Oct)
- [ ] **P0 · Off by default.** Settings toggle starts the server; toggle-off or quit drops all sessions. Toggle off → `ss -ltn | grep 47820` is empty.
- [ ] **P0 · Bind one private IPv4** (10/8, 172.16/12, 192.168/16), never `0.0.0.0`. Use `if-addrs`; **skip** `lo`, `docker*`, `br-*`, `virbr*`, `veth*`, `tailscale*`/`tun*`/`wg*`, 100.64/10 (CGNAT/Tailscale), 169.254/16. Prefer the interface on the default route (Linux: `/proc/net/route`, dest `00000000`). Show a picker if more than one remains.
- [ ] **P0 · Pairing.** 128-bit token, base64url, 120 s, single use, one outstanding. QR = `http://<ip>:47820/#p=<token>`: it sits in the fragment, so it never reaches HTTP logs. `hello{pair}` → 256-bit session token in `localStorage`; server keeps a SHA-256 hash (`sha2`, already a dep) in RAM; compare with `subtle`. JS clears `location.hash` after pairing.
- [ ] **P0 · Checks.** Only `GET /` and `GET /ws`. `Host` == `<ip>:<port>`, WS `Origin` == `http://<ip>:<port>` (blocks DNS rebinding). Frames ≤ 4 KB. No hello within 10 s → close. Max 3 sessions. 5 failed hellos/IP/min → 60 s ban (small in-RAM map, no `tower_governor`). ≤ 10 cmds/s.
- [ ] **P0 · Caps.** ERG ±50 W per command; remote ceiling 600 W (setting); end_save needs `hold_ms ≥ 1500` (the page enforces a hold button; the server checks the field).
- [ ] **P0 · UI copy on HTTP:** home Wi-Fi only; plain HTTP means no Wake Lock (the phone may lock mid-ride; tip: raise auto-lock), and anyone on the Wi-Fi could sniff a session. The caps bound the harm. P1: HMAC per message with a key from the QR secret.

## 4. Network gotchas
- [ ] **P0 · Garuda:** no firewall enabled by default. Check with `systemctl is-active firewalld ufw`. If on:
  - firewalld: `sudo firewall-cmd --zone=home --add-port=47820/tcp --permanent && sudo firewall-cmd --reload`, then put Wi-Fi in home: `nmcli connection modify "<SSID>" connection.zone home` (Arch default zone is `public`).
  - ufw: `sudo ufw allow from <192.168.1.0/24> to any port 47820 proto tcp comment 'Tacx remote'`.
  Show both as copy buttons with the real subnet filled in.
- [ ] **P0 · No mDNS.** The QR carries the IP. Don't touch avahi (port 5353 clashes and `.local` doesn't resolve on Android). Port 47820 is fixed; if busy, try 47821–47829 and show which.
- [ ] **P0 · Windows:** the first LAN bind triggers the Defender prompt for `tacx_desktop.exe`. Copy: "Tick **Private networks** → Allow". If the network is Public: Settings → Network → set to Private.
- [ ] **P1 · IP changed** (DHCP/Wi-Fi switch): server rebinds on toggle; phone shows "re-scan QR".

## 5. Protocol v1 (shared codec module `proto` → becomes `race-proto` in step 6)
Envelope: `{"v":1,"t":"<type>","seq":n,...}`, serde `#[serde(tag="t")]` enums `ClientMsg`/`ServerMsg`; unknown `v` → `error{code:"upgrade"}`.
| C→S | Maps to | Slice |
|---|---|---|
| `hello{pair?|session?, device}` | token swap → `hello_ok` | P0 |
| `erg_delta{w}` | clamp ±50 → `target = metrics.target_power_w + w`, clamp to `get_power_range()` and ceiling → `set_target_power` | P0 |
| `pause` / `resume` | `set_ride_paused(true/false)` (+ workout engine pause in P1) | P0 |
| `end_save{hold_ms}` | `end_effort(true)` → Dart gets `RideEnded` and runs its normal summary/ghost flow → `export_effort_tcx(id, None)` → `ride_ended{path, summary}` | P0 |
| `set_grade{pct}` | `set_track_resistance(pct, DEFAULT_SIM_CRR)`, gated on sim support + not driven by GPX/workout | P1 |
| `set_resistance{pct}` | `set_resistance_percent`, clamp to range | P1 |
| `start{kind, id?}` | `start_workout(id)` / free ride → `begin_effort(kind, demo)` | P1 |
| `skip` | net-new `WorkoutEngine::skip_step()` (rebase schedule at now) | P1 |
| S→C | | |
| `hello_ok{session, caps{sim, res, power, ceiling}, rev}` · `error{code}` · `bye{reason}` | | P0 |
| `state{rev, p, cad, hr, spd, target, mode, demo, effort{id, el_s, moving_s, paused}, wo{i, n, rem_s, next?}}` at 4 Hz riding / 1 Hz idle, plus one push after every command | `get_metrics`, `get_connection_snapshot`, `current_effort`, `get_workout_status` | P0 (`next` P1) |
| `ride_ended{slice_id, path, np, tss, dur_s}` | from `effort_summary`; also sent when the desktop ends the ride (subscribe to the same event source) | P0 |
- [ ] **P0 · `control_rev` + last-write-wins.** Every applied change bumps an `AtomicU64` and records `last_source`. Dart 250 ms poll reads `remote_control_rev()` and resyncs `_targetWatts` and similar, toast "Phone: ERG 210 W".
- [ ] **P0 · Demo honesty:** `state.demo` true → page shows a DEMO badge; end_save in Demo keeps `Notes=DEMO`, no ghost (existing rules apply because it goes through `end_effort`).
- [ ] **Reuse for step 6:** codec, hello/version, ping/pong, backoff (1,2,4,8,15 s), token gen + hash store move into `proto`. The relay never accepts `ClientMsg` control variants.

## 6. First PR (R1, one cycle)
1. `rust/Cargo.toml`: tokio `+net`; `axum` (lean), `qrcode` (svg), `if-addrs`, `subtle`, `getrandom`; dev `tokio-tungstenite 0.28`.
2. `rust/src/remote/{mod.rs, server.rs, auth.rs, net.rs, proto.rs, index.html}`: server on `runtime()`, iface picker, tokens, Host/Origin checks, handlers for hello / erg_delta / pause / resume / end_save, state broadcast via a `tokio::sync::watch`.
3. `rust/src/api/remote.rs` (FRB): `remote_start(ip?) -> RemoteInfo`, `remote_stop()`, `remote_pair() -> PairInfo{url, qr_modules, qr_width, expires_ms}`, `remote_sessions()`, `remote_kick(id)`, `remote_control_rev()`. Regenerate `frb_generated.rs`.
4. Flutter: `lib/.../remote_settings.dart` (toggle + iface picker + firewall tips) and `remote_pair_dialog.dart` (QR + countdown + device list).
5. Tests (`rust/tests/remote.rs`, holding `GLOBAL_TEST_LOCK`, Demo trainer, loopback allowed under `cfg(test)`): pair → `erg_delta +10` → `state.target` +10; end_save → `ride_ended.path` exists and one `RideEnded`; expired (paused clock +121 s) and reused token rejected; bad Origin/Host → 403; ±50 W clamp; 4 KB+ frame closed. Unit: interface filter rejects public, `docker0`, 100.64/10. Widget test for the dialog.
*Done when:* CI green; manual: Android Chrome + iPhone Safari control a Demo ride on Garuda; p95 cmd→BLE write < 300 ms logged.

**Later:** P1 workout pause/skip/next + start/grade/resistance, devices panel with Kick, HMAC; P2 lap + multi-`<Lap>` TCX, "remember phone 30 days", Option C over the step-6 relay (HTTPS + E2E).
