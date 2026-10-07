# tacx-desktop: phone/tablet remote checklist
*Written 2026-10-08 (Brussels) against `main` @ `3ac394f`. Read-only research: no code, PRs or commits. For Tacx Build.*
*Legend: **P0** = first milestone (R1) · **P1** = next · **P2** = later. "Exists" = real function today; "net-new" = Build must add it. Effort figures are estimates.*

**Recommendation:** ship **Option A first**: the desktop serves a single-page web remote from the Rust core (axum HTTP + WebSocket, bound to one LAN IP), paired by a QR code, opened in the phone's browser with nothing to install. Do B only if A's HTTP limits hurt; C comes after the step 5 race relay.
**Golden rule (same as multiplayer):** the remote is an overlay. If the remote crashes, disconnects or gets flooded, trainer control, ERG/SIM and recording carry on unchanged.

## 1. Options
| | A: local web remote | B: Flutter companion app | C: remote over the race relay |
|---|---|---|---|
| Effort (est.) | 4–6 dev-days | 2–3 weeks plus store review | 3–5 days *after* the relay exists |
| UX | Scan QR → page opens; no install; re-scan if desktop IP changes | Native; mDNS auto-discovery; wake lock; push haptics | Works off the LAN (4G); needs internet |
| Reach | Any phone/tablet browser (iOS Safari, Android Chrome) | Android + iOS builds; Apple $99/yr, Play $25 once; signing and review | Any browser, served over HTTPS by the relay |
| Maintenance | One ~40 KB HTML/JS file embedded in the core `.so`/`.dll` | Second app, two stores, OS permission churn | Relay uptime; extra E2E layer |
| Platform gotchas | Plain HTTP means no service worker, no Wake Lock and no WebCrypto (secure context only) | iOS: `NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_tacxremote._tcp`); Android: cleartext `network_security_config` for `ws://`, multicast lock | Relay must never be able to inject commands (see Reuse) |
- [ ] **P0 · Build Option A (milestone R1).** *Done when:* an iPhone (Safari) and an Android phone (Chrome) on the home Wi-Fi each control a Demo ride and a live trainer on Garuda and Windows.
- [ ] **P2 · Option B** only if users need wake lock, background or auto-discovery. Reuse the same protocol (`web_socket_channel`, `bonsoir` MIT for mDNS, `mobile_scanner` BSD-3 for QR).
- [ ] **P2 · Option C** = relay "remote room" plus a pairing step (see Reuse). It's also the fix for HTTPS.

## 2. Controls and live data (mapped onto `rust/src/api/trainer.rs` and `controller.rs`)
The core already holds global `RUNTIME` + `controller()` singletons. Spawn the axum server on `runtime()` and call the controller directly. No Dart round-trip for commands.
| Remote action | Maps to | Status |
|---|---|---|
| ERG set / ±5 / ±10 W | `set_target_power(w)`. The server resolves `erg_nudge{dw}` against the **current Rust target** (`metrics.target_power_w`), clamped to `get_power_range()` | Exists. Nudge resolution is net-new (desktop nudges a Dart-only `_targetWatts`) |
| Resistance % | `set_resistance_percent(pct)`, clamped to `get_resistance_range()` | Exists |
| Sim grade | `set_track_resistance(grade, DEFAULT_SIM_CRR)`, gated on `snapshot.supports_simulation` | Exists |
| Start workout / stop | `list_workouts()`, `start_workout(id)`, `stop_workout()` (+ `stop_interval`, `stop_gpx_route` like the Focus Stop) | Exists |
| Pause / resume workout | `WorkoutEngine::pause/resume`. `run_steps` uses an absolute schedule from `t0`, so add a paused-time offset. On pause, hold ERG at min(current, 100 W) | **Net-new** |
| Skip step | `WorkoutEngine::skip_step()`: bump the index and rebase the schedule at "now" | **Net-new** |
| Lap | `ride::mark_lap()`. `tcx::render` takes one `LapSummary` today, so it needs multi-`<Lap>` output | **Net-new (P1)** |
| End ride + save | Stop the drivers, then `export_ride_tcx(None)` → path. Ghost `AttemptRecorder` and summary live in Dart (`route_ghost.dart`), so push a `RemoteEvent::RideEnded` to Dart | Export exists; event net-new |
| Live power/cad/speed/HR | `try_metrics()` (HR already strap-merged via `hr_strap::overlay`) | Exists |
| Step N/M, time left, target | `get_workout_status()`: `step_index`, `step_count`, `remaining_s`, `target_watts`, `target_grade_pct` | Exists |
| Next step | Add `next_kind`, `next_watts`, `next_grade_pct`, `next_duration_s`, `paused` to `WorkoutStatus` | **Net-new** |
| Route progress, ride totals, connection | `get_route_status()`, `ride::stats()`, `try_snapshot()` (`is_demo`, `mode`, `state`) | Exists |
- [ ] **P0 · Command handler** `remote::handle(cmd) -> Result<Ack>` calls the functions above. *Done when:* every row marked "Exists" works from the phone in Demo.
- [ ] **P0 · Conflict rule = last write wins, server-authoritative.** Every applied change (desktop or phone) goes through the controller mutex, bumps `control_rev`, and records `last_source` (`desktop` or `phone:<name>`). The phone sends nudges as **deltas**, so two devices nudging both count. *Done when:* desktop sets 200, phone +10 → both show 210 within 0.5 s.
- [ ] **P0 · Desktop resync.** The 250 ms Dart poll reads a new `remote_take_events()` (or `control_rev`). When the rev changes, sync `_targetWatts`/`_resistancePct` from metrics and toast "Phone: ERG 210 W". *Done when:* the desktop never shows a stale pending value after a phone change.
- [ ] **P0 · Mode gating mirrors the desktop.** While a workout/route drives the trainer, resistance/grade are disabled and ERG ± is an override until the next step (same as the desktop today). Grade is disabled when sim isn't supported. *Done when:* the phone greys out the same controls the desktop does.
- [ ] **P0 · Safety caps.** One command can move ERG by at most ±50 W. A remote ERG ceiling (default 600 W, setting). End ride needs a 1.5 s hold. *Done when:* `erg_set{w:2000}` is refused unless the ceiling allows it.
- [ ] **P1 · Pause/skip + next step + lap** (the net-new rows). Tests use `tokio::time::pause()` like the existing engine tests.
- [ ] **P0 · Broadcast** `state` at **4 Hz while riding, 1 Hz idle**, plus an immediate push after each ack. *Done when:* about 0.5 KB per frame and the phone UI updates in under 300 ms.

## 3. Security (no accounts)
- [ ] **P0 · Off by default, on per session.** A "Phone remote" toggle in the normal chrome starts the server; app quit or toggle off stops it and drops every session. *Done when:* with the toggle off, nothing listens (`ss -ltnp | grep tacx` is empty).
- [ ] **P0 · Bind to one private IPv4**, never `0.0.0.0`. List interfaces (`if-addrs`/`local-ip-address`) and allow only RFC 1918 (10/8, 172.16/12, 192.168/16). Pick the default-route interface and let the user choose another. Refuse public IPs; CGNAT/Tailscale 100.64/10 is P2 opt-in. *Done when:* a test shows a public or `0.0.0.0` bind is rejected.
- [ ] **P0 · One-time pairing token.** "Pair a phone" makes 128 random bits (`getrandom`), base64url, valid **120 s, single use**, one outstanding at a time. The QR encodes `http://<ip>:<port>/#p=<token>`. It sits in the **URL fragment, so it's never sent in the HTTP request or logs**. JS sends it in `hello`; the server swaps it for a **256-bit session token** stored in `localStorage` (server keeps only the SHA-256 hash, in RAM). Compare in constant time (`subtle`). *Done when:* expired or reused tokens get `error{code:"pair_invalid"}`.
- [ ] **P0 · Sessions in RAM only.** They end on toggle-off or app quit (re-scan after restart). Max 3 devices. **P1:** "Remember this phone for 30 days" with hashes in the config dir.
- [ ] **P0 · Connected devices panel.** Name (UA-derived, user can rename), IP, since, last command, and a **Kick** button (sends `bye{reason:"kicked"}` and revokes the session).
- [ ] **P0 · Request checks.** Only `GET /` (embedded HTML) and `GET /ws`. **`Host` must equal `<bound-ip>:<port>`** (blocks DNS rebinding). **WebSocket `Origin` must equal `http://<bound-ip>:<port>`**. Frames ≤ 4 KB. Unauthenticated sockets close after 10 s.
- [ ] **P0 · Rate limits.** 5 pairing/hello failures per IP per minute, then a 60 s ban (`tower_governor` or a small in-RAM map). ≤10 commands/s per session (excess dropped, nudges coalesced). Ping every 10 s; close after 30 s with no pong.
- [ ] **P0 · HTTP trade-off, written in the UI copy.** A home WPA2/3 LAN with plain HTTP + token is acceptable for R1. Someone on the same Wi-Fi could sniff the session token and nudge the trainer. The caps above bound the harm; HR is visible but never stored. Self-signed HTTPS makes iOS/Android show full-page warnings, so it's worse UX for no real gain. Also: on HTTP there's no WebCrypto, service worker or Wake Lock.
- [ ] **P1 · Cheap hardening.** Per-message HMAC-SHA256 (`@noble/hashes`, MIT, pure JS) keyed from the QR secret (it never crosses the wire), with a `seq` counter for replay. A sniffer then can't forge commands. **Later real fix:** C over relay HTTPS with E2E, or B with cert pinning. A plex.direct-style wildcard cert for LAN IPs is possible but needs infra (P2).

## 4. Firewall
- [ ] **P0 · Fixed default port 47820** (setting; if it's busy, try 47821–47829 and show the one in use). Firewall rules need a stable port.
- [ ] **P0 · Garuda: verify first.** Current Garuda ships **no firewall enabled** (firewalld disabled by default; the wiki says ufw is preinstalled on most editions). Check with `systemctl is-active firewalld ufw`.
  - firewalld: `firewall-cmd --get-active-zones`, then `sudo firewall-cmd --zone=home --add-port=47820/tcp --permanent && sudo firewall-cmd --reload`. Put the Wi-Fi in home: `nmcli connection modify "<SSID>" connection.zone home` (Arch default zone is `public`).
  - ufw: `sudo ufw allow from 192.168.1.0/24 to any port 47820 proto tcp comment 'Tacx remote'` (use your own subnet).
  - *Done when:* the Remote panel shows these as copy buttons with the real port/subnet filled in, and a "Phone can't connect?" tip.
- [ ] **P0 · Windows.** The first non-loopback listen triggers the **Defender Firewall prompt** for `tacx_desktop.exe`. Copy: "Tick **Private networks**, click Allow". If the user cancels, a block rule is made; fix it in *Allow an app through firewall*. Windows 11 often marks new Wi-Fi as **Public**, so tell users to switch it to **Private** (Settings → Network → Wi-Fi → Network profile type). *Done when:* there's a tested walkthrough with screenshots in the README.
- [ ] **P2 · Inno installer rule:** `netsh advfirewall firewall add rule name="Tacx Desktop Remote" dir=in action=allow program="{app}\tacx_desktop.exe" protocol=TCP localport=47820 profile=private`, removed on uninstall.

## 5. Libraries (checked on crates.io/pub.dev/npm 2026-10-08; all MIT-compatible)
- [ ] **P0 · Rust:** `axum` 0.8 (`ws` feature, MIT), add `net` to the existing `tokio` features, `tower-http` 0.7 (MIT; `trace`/`limit`), `rust-embed` 8 (MIT) to embed `web/remote/` into the core library (no extra files in the tar.gz/Inno), `if-addrs` 0.15 (MIT/BSD-3) or `local-ip-address` 0.6 (MIT/Apache-2.0), `getrandom` 0.4 + `base64` 0.23 + `sha2` (already there), `subtle` 2.6 (BSD-3), `tower_governor` 0.8 (MIT/Apache-2.0). Size impact ≈ +1–2 MB (est.); measure it.
- [ ] **P0 · QR:** Flutter `qr_flutter` 4.1 (BSD-3) draws from the `pair_url` Rust returns. The Rust `qrcode` 0.14 (MIT/Apache-2.0) isn't needed unless we print a QR in the terminal.
- [ ] **P0 · Web UI:** plain HTML + vanilla JS, one file, ≤40 KB, no build step. Mobile-first dark theme reusing `AppTokens` colours, tabular digits, **tap targets ≥56 px**, landscape for tablets, a "Reconnecting…" overlay. `manifest.json` + `apple-touch-icon` for Add to Home Screen. With no service worker on HTTP, "offline" means the page stays up and reconnects. Preact 11 (MIT) only if it outgrows vanilla.
- [ ] **P0 · FRB API (net-new):** `list_lan_interfaces()`, `remote_start(iface, port) -> RemoteInfo{url, pair_url, expires_s}`, `remote_new_pair()`, `remote_stop()`, `remote_status() -> {enabled, clients[]}`, `remote_kick(id)`, `remote_take_events() -> Vec<RemoteEvent>` (polled by the 250 ms timer).

## 6. Reuse with the step 5 race relay
- [ ] **P0 · One protocol module now, a crate later.** Keep `rust/src/proto/` (serde enums, `#[serde(tag="t")]`, envelope `{v, t, …}`) inside the core for R1. Extract it to `tacx-proto` when the relay starts, as the race module next to the remote module. JSON for the remote (easy to debug in a browser); MessagePack (`rmp-serde`) for the relay. Same structs, so both formats come free.
- [ ] **P0 · Shared pieces:** axum+ws server skeleton, `hello`/`welcome` handshake, version check (`error{code:"upgrade"}`), ping/pong + clock offset, reconnect backoff (1, 2, 4, 8, max 15 s) in the JS and Dart clients, random token generator + hashed-token store, rate limiter, `bye` reasons.
- [ ] **P0 · Must differ:** remote = **control** (writes to the trainer); relay = **telemetry** (positions only). The relay never accepts `cmd` frames. Control commands are accepted **only** on the LAN listener from a paired session. Race tokens are anonymous and per race; remote sessions belong to a device.
- [ ] **P2 · C over relay:** the desktop opens an outbound WSS "remote room"; the phone opens `https://relay/r/<code>#k=<secret>`. Commands are **E2E-signed/encrypted with the QR secret** (WebCrypto works over HTTPS), so the relay can't forge them. Off by default; the desktop shows "Remote via internet" while it's active.

## 7. Message protocol sketch (v1, JSON over `ws://<ip>:47820/ws`)
```
C→S hello   {v:1, pair?:"<128b>", session?:"<256b>", device:"iPhone Safari"}
S→C welcome {session, server_ms, rev, caps:{sim, res:{min,max,step}, power:{min,max}, erg_ceiling}, workouts:[{id,name}]}
S→C error   {code:"pair_invalid"|"session_invalid"|"upgrade"|"rate_limited"|"bad_origin", msg}
S→C state   {rev, ms, conn:{state, demo, mode, device}, m:{p, cad, spd, hr, tw, res},
             wo:{run, paused, name, i, n, rem_s, tw, grade, next:{kind, w, grade, dur_s}},
             route:{run, prog_m, dist_m, grade}, ride:{el_s, km, avg_w, rec}, last:{by, what}}   // 4 Hz riding, 1 Hz idle
C→S cmd     {id, seq, c:"erg_set",w | "erg_nudge",dw | "res_set",pct | "grade_set",pct |
             "wo_start",wid | "wo_stop" | "wo_pause" | "wo_resume" | "wo_skip" | "lap" | "ride_end_save"}
S→C ack     {id, ok, err?, rev, path?}         // path = saved TCX for ride_end_save
C↔S ping    {ms} / pong {ms, server_ms}       S→C bye {reason:"kicked"|"remote_off"|"session_expired"}
```

## 8. Tests
- [ ] **P0 · Rust unit:** command handler (clamps, ±50 W cap, ceiling, nudge resolution against the live target, mode gating, sim gating), token lifecycle (expiry, single use, constant-time compare), Host/Origin validation, interface filter (rejects public and `0.0.0.0`). Hold `GLOBAL_TEST_LOCK` like the existing controller tests.
- [ ] **P0 · Integration:** `tokio-tungstenite` 0.30 (MIT, dev-dep) against a real server on `127.0.0.1` (test-only loopback allowance) in **Demo**: pair → session → `erg_nudge +10` → `state.m.tw` = old+10 → `ride_end_save` returns a TCX path. Run it in CI next to `run_headless_demo_smoke`.
- [ ] **P0 · Security:** expired token, reused token, wrong `Origin`, wrong `Host`, no hello within 10 s, 11 commands/s, 4 KB+ frame, kicked session reconnecting → all refused with the right `error`/`bye`.
- [ ] **P1 · Browser smoke:** Playwright (Chromium + WebKit, mobile viewport) loads `/#p=…`, taps +10, checks the displayed target and that the token is gone from `location.hash` after pairing.
- [ ] **P0 · Manual on real devices:** Android Chrome + iOS Safari × Garuda (firewall off, then firewalld/ufw on) + Windows (Private, then Public profile). Check: pair, ERG ±, resistance, grade, workout start/stop, end + save, kick, desktop IP change → re-scan, phone screen lock → reconnect.
- [ ] **P0 · Latency:** log `cmd recv → BLE write issued`. Target **p95 < 300 ms on LAN** (FE-C's 4 Hz limiter adds up to 250 ms; Kickr's 3–5 s settle isn't counted). *Done when:* the numbers are in the PR.

## Top 5 for Build
1. **Rust `remote` module (R1 core):** axum+ws on the existing `runtime()`, bound to one chosen private IPv4 on port 47820, off by default, single-file web UI embedded with `rust-embed`, plus the FRB `remote_*` API.
2. **Pairing + hardening:** QR (`qr_flutter`) with a 128-bit, 120 s, single-use token in the URL fragment, swapped for a hashed session token. Host + Origin checks, rate limits, max 3 devices, devices panel with Kick.
3. **Command handler on existing functions:** `set_target_power` (server-side nudges), `set_resistance_percent`, `set_track_resistance`, `start/stop_workout`, `export_ride_tcx`. `control_rev`/`last_source` with Dart resync, safety caps, state at 4 Hz.
4. **Net-new engine bits:** `WorkoutEngine` pause/resume/skip (schedule offset), next-step fields in `WorkoutStatus`, `RideEnded` event to Dart for ghost/summary. Lap + multi-`<Lap>` TCX is P1.
5. **Tests + firewall UX:** `tokio-tungstenite` Demo integration test and security tests in CI, Garuda firewalld/ufw copy buttons, Windows "Private network" walkthrough, real-phone pass, p95 < 300 ms.
