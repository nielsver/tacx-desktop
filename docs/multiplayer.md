# tacx-desktop: multiplayer v2, "Race mode, no accounts" (roadmap step 5)

*v2 written 2026-10-08 (Brussels) against `main` @ `155eeba`. Read-only research; no code, PRs or commits. The v1 accounts/Supabase plan is kept in `tacx-desktop-multiplayer-checklist-v1-accounts.md`.*
*Prices were checked 2026-10-08 and exclude VAT. **(est.)** = my estimate, to be confirmed by the load test in B3.*

**Idea:** online is a race you simply connect to. You get a room code, type a nickname, ride one GPX, see live gaps, and get finish order and results. Then the room disappears. No accounts, no database, no stored personal data. **Golden rule:** networking is an overlay; a network failure never touches trainer control or local recording.
**Reuse:** the v2 route key + trimming from `tacx-desktop-pro-polish-checklist.md` (RI2: SHA-256 over 128 resampled lat/lon/elev points + distance, computed in `gpx.rs`); `GhostTrack.timeAt` logic for time gaps (`route_ghost.dart`); the 3-2-1 countdown from the Pro workout view; the reconnect banner style; tokio, already in `rust/Cargo.toml`.

## Joining
- [ ] **J1 P0 · Room code.** The server makes 6 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (32 symbols, no 0/O/1/I), which is 32⁶ ≈ 1.07 billion codes. Show it as `ABC-123`; input is case-insensitive and ignores the dash. Allow ≤ 10 join attempts per minute per IP so codes can't be guessed. *Done when:* code input accepts `abc123` and `ABC-123`, and the 11th wrong guess in a minute is refused.
- [ ] **J2 P0 · Plain code paste always works** (the "Race" screen: Create / Join, with a code field). This is the baseline on every OS and package format.
- [ ] **J3 P1 · Invite link `tacxdesktop://race/ABC123`** (plus `?s=host:port` for host-run rooms) via `app_links` 7.2.2. Its README shows custom schemes ✔ on Linux and Windows. **Linux:** `linux/runner/my_application.cc` must become single-instance: replace `G_APPLICATION_NON_UNIQUE` (line 153 today) with `HANDLES_COMMAND_LINE|HANDLES_OPEN`, and the `.desktop` file needs `Exec=… %u` and `MimeType=x-scheme-handler/tacxdesktop;`. The `.deb` and tar.gz `install.sh` can install that file. An AppImage only registers if the app writes `~/.local/share/applications/…desktop` and runs `xdg-mime default` (an opt-in "Enable race links" button). **Windows:** call `SendAppLinkToInstance()` in `windows/runner/main.cpp` and register `HKCU\Software\Classes\tacxdesktop` from the Inno script (`packaging/windows/tacx-desktop.iss`, `[Registry]`). Many chat apps don't make custom schemes clickable, so the invite text always includes the plain code. *Done when:* clicking the link in Firefox on Garuda (.deb) and in Edge on Windows (Inno) opens or focuses the app with the code pre-filled. Re-test `window_manager` after the single-instance change.
- [ ] **J4 P0 · Nickname.** 2–16 characters, typed on first join and saved locally only (`shared_preferences`). If two riders in a room pick the same name, the server adds `#2`. *Done when:* the nickname is never written anywhere server-side (code review + log grep).
- [ ] **J5 P0 · Anonymous session token.** On join the server issues 128 random bits. The client keeps it in RAM only and uses it for `resume`. It dies with the room. *Done when:* a resume after the room closes fails with `room_gone`.
- [ ] **J6 P2 · https invite page** on the relay domain (`https://race.<domain>/ABC123` shows the code and an "Open in Tacx Desktop" button). Static, no tracking.

## Race flow
- [ ] **R1 P0 · Create room.** The host picks a GPX. The app makes the **canonical race route**: the Pro-polish trim (500 m off each end, GPX metadata stripped) → route key v2 computed on *this* trimmed route. `create_room` uploads the route (d/elev/lat/lon samples, ≤ 300 KB). The server keeps it **in memory** and sends it to joiners, so nobody needs the file. Each joiner recomputes the key on what it received and must match. *Done when:* a joiner with no GPX rides the same profile and the keys match; a tampered route is rejected.
- [ ] **R2 P0 · Lobby.** Shows the players, ready toggles, route name/length/climbing, and the host's settings (max 8 players in v1). The host can Start when every present player is ready (≥ 1, so you can test solo) and can kick. *Done when:* 3 clients see ready states change within 1 s.
- [ ] **R3 P0 · Synced countdown.** The server sends `countdown{start_at_ms}` (server clock, start = now + 10 s). Each client's clock offset comes from ping/pong (keep the sample with the lowest RTT out of 5). The 3-2-1 widget is reused. At `start_at` the client starts the route in **SIM mode** (ERG is disabled in races). *Done when:* the starts of 3 clients on different networks are within 150 ms of each other.
- [ ] **R4 P0 · Live race at 2 Hz.** The client sends `state{seq, watts, cadence}` at 2 Hz. The **server is authoritative for distance**: it integrates speed from watts with the shared physics (F1). The client runs the same model locally so the trainer grade and your own marker respond instantly, and snaps to the server's distance if they differ by more than 5 m. The server sends `snapshot` at 2 Hz: distance, speed, place, and the **time gap** to the leader (the leader's d→t history, `timeAt`-style). Other riders are drawn 500 ms behind live, interpolated, and extrapolated ≤ 2 s. *Done when:* 8 riders at 2 Hz show smooth markers and gaps under a 200 ms jitter netem test.
- [ ] **R5 P0 · Finish + results.** At `d ≥ dist` the server records finish time from `start_at` and broadcasts `finish{id, place, time_s}`. The race ends when everyone has finished or is DNF, or at a cutoff (leader + 15 min, 4 h hard cap). `results` lists place, nickname, time or DNF, avg W, and flags. The app shows a results screen and can save a local JSON to `Documents/Tacx Desktop/races/` (your own disk only). *Done when:* a 3-rider Demo-free test produces the correct order.
- [ ] **R6 P0 · Disconnect.** No `state` for 3 s → the rider is "reconnecting": shown grey, distance frozen. `resume{session_token}` within **60 s** continues from the frozen distance; after that the rider is **DNF**. Riding while offline doesn't count in v1. Explicit `leave` = DNF. If the host drops on the VPS relay, the host role passes to the next player. The client uses backoff of 1/2/4/8 s and the existing banner, and the trainer keeps going. *Done when:* pulling the cable for 20 s resumes the race; for 70 s gives DNF; ERG/SIM never stalls.
- [ ] **R7 P0 · No late joiners after the countdown** (`error{code:"race_started"}`). **P2:** spectate.
- [ ] **R8 P0 · Room lifetime.** A lobby with no activity for 30 min is deleted; a room is deleted 5 min after results; the server keeps nothing after a restart. *Done when:* the server's memory returns to baseline after 100 simulated races.

## Backend (simplest first; state-light: memory only, no DB)
| Option | Effort | Cost | Reality check |
|---|---|---|---|
| **1. Rust/axum WS relay on Hetzner** | Low–Med: one static binary + Caddy TLS + systemd | CX23 €5.49 + IPv4 €0.50 (20 TB traffic) | Always reachable, EU (FSN/NBG/HEL), German company. CX23 is sometimes out of stock; CAX11 (Arm) is €5.99 + IPv4 |
| **2. Same relay run by the host player** | Low (embed the relay crate in the core: a "Host on this PC" button) | €0 | LAN works. Over the internet the host needs port forwarding. Most Belgian fixed lines have public IPv4, but forum reports show some lines behind CGNAT (10.x/100.64.x WAN), Proximus blocks some ports, and 4G/5G home internet is CGNAT. The Windows firewall prompt and Garuda firewall also need handling. Host leaves = race over |
| **3. Public tunnel** (Cloudflare Quick Tunnel `cloudflared tunnel --url`) | Low–Med (bundle `cloudflared`, embed the tunnel host in the invite) | €0 | No account needed, but Cloudflare says "testing and development" only: no uptime guarantee, a new hostname each run, 200 in-flight requests max |
| **4. WebRTC data channels** | High: you still need a signalling server + STUN/TURN, plus `webrtc-rs`/`flutter_webrtc` on desktop | Signalling server + TURN (Cloudflare $0.05/GB after 1000 GB free per month) | Mesh with no authority, so **server-side fairness is impossible**; NAT traversal is flaky. Not worth it at 2 Hz × 8 riders |
- [ ] **B1 P0 · Default = option 1** (Hetzner CX23, Falkenstein or Nuremberg). `server/` crate: axum `ws`, a `HashMap<RoomCode, Room>` behind tokio tasks (one task per room, ticking at 2 Hz), Caddy for TLS, no access logs. *Done when:* `wss://race.<domain>/ws` passes the R-items end to end.
- [ ] **B2 P1 · Fallback = option 2**, the same relay crate in-process ("Host on this PC", listening on `0.0.0.0:7878`), plus a "Direct connect host:port" field and a LAN hint. The UI is honest: "friends outside your network need port forwarding; CGNAT/4G won't work". *Done when:* a LAN race between Garuda and Windows works with no VPS.
- [ ] **B3 P0 · Load test.** A `bot` binary simulates N riders. Target: 200 rooms × 8 bots on a CX23, p99 snapshot jitter < 50 ms, CPU < 50%. *Done when:* the numbers are recorded in the repo docs.
- [ ] **B4 P2 · Option 3 experiment**, flag-gated, for LAN-less friends without a VPS. Never the default.

## Fairness
- [ ] **F1 P0 · Shared physics crate `race-physics`** (a workspace crate used by the core and the server). `speed = f(watts, grade(d), mass, CdA, Crr, wind = 0)` with fixed per-race CdA/Crr. The **server recomputes speed from reported watts and ignores any client speed or distance.** This also fixes today's wheel-speed progress (`controller.rs`), so a Kickr and a Tacx compare fairly. *Done when:* the same watts file gives the same distance on server and client (±0.5%), with golden tests.
- [ ] **F2 P0 · Sanity limits (server).** Watts 0–2000 (clamp + flag above that). Cadence 0–200. Rolling W/kg ceilings flag at 5 s > 25, 1 min > 12, 5 min > 8, 20 min > 6.5. Rider weight is **self-reported**: clamp 40–150 kg and show "weight self-reported" on results. Watts > 300 with cadence 0 for > 5 s → warn only (some trainers don't send cadence). `seq` must increase; ≤ 5 msg/s (kick above that); a state gap > 3 s counts as 0 W. Position jumps can't happen because the server owns distance. *Done when:* tampered fixtures raise the right flags.
- [ ] **F3 P0 · Demo excluded.** The client hides Race in Demo mode, and `join` carries `demo:false`; the server refuses `demo:true`. *Done when:* tests cover both sides.
- [ ] **F4 P0 · Honesty in the UI:** results show ⚠ for flagged riders. Say plainly that **a modded client can still send fake watts within the limits**; the defence is private codes among friends plus host kick.

## Privacy (no accounts, no storage)
- [ ] **PV1 P0 · What is still personal data:** IP addresses (connections and rate limiting), nicknames and watts during a live room, self-reported weight (sent at join, used for physics, **never broadcast, never stored**). **HR is never sent** (Art. 9 health data). *Done when:* the protocol has no HR field and the server has no disk writes except the binary and its config.
- [ ] **PV2 P0 · Minimal logs:** Caddy access log off; app logs contain no IPs or nicknames (room code + event only). The rate-limit table keys IPs in memory with a 10-min TTL. Accept Hetzner's DPA (AVV) in the console. EU hosting only.
- [ ] **PV3 P0 · Short privacy note** (NL/EN) on the Race screen: "Your nickname, watts and cadence go to our EU server only during the race and are deleted when the room closes. Weight is used to calculate speed and is not shared. IP addresses are used briefly for abuse protection and not stored. No account, no tracking." Lawful basis: providing the race you asked for (Art. 6(1)(b)). The Belgian DPA (gegevensbeschermingsautoriteit.be) only comes in if there's a breach.
- [ ] **PV4 P0 · Trimmed routes only** (R1), so the host's home location isn't sent to strangers.

## Protocol v2 (WSS; JSON first via a serde `{"t":…}`-tagged enum, MessagePack later by switching serializer: `rmp_serde::to_vec_named`, same types)
```
C→S create_room {proto:2, app_version, route_key, route:{dist_m, pts:[[d,elev,lat,lon]]}, max_players}
S→C room_created {code, session_token, server_ms}
C→S join     {proto:2, code, nickname, route_key, app_version, mass_kg, demo:false}
S→C joined   {session_token, server_ms, you:id, host:id, route?, players:[{id,nick,ready}]}
C→S ready    {ready:bool}                   S→C lobby     {players:[{id,nick,ready}], host:id}
C→S start    {}   (host only)               S→C countdown {start_at_ms, server_ms}
C→S state    {seq, watts, cadence}          S→C snapshot  {server_ms, players:[{id, d_m, v_mps, w, place, gap_s, st:"ok"|"recon"|"fin"|"dnf"}]}  (2 Hz)
C→S resume   {session_token}                S→C finish    {id, place, time_s}
C→S leave    {}                             S→C results   {rows:[{place, nick, time_s|null, avg_w, flags}]}
C→S ping     {client_ms}                    S→C pong {client_ms, server_ms} · error {code, msg} · kicked {}
```
- [ ] **PR1 P0 · Protocol types live in a shared crate** (`race-proto`, serde). Unknown `proto` → `error{code:"upgrade"}`. A route key mismatch on join → `error{code:"route_mismatch"}`. *Done when:* round-trip tests in JSON and MessagePack pass.

## Cost (recommended: Hetzner relay; host-run = €0)
- **Bandwidth per rider (est.), 8-rider race:** about 180 B/s up (2 × ~90 B including TCP/WS overhead) and 400 B/s down (2 snapshots × ~200 B), so ≈ 0.6 KB/s ≈ **2.1 MB per rider-hour**. 20 TB/month included ≈ 9 million rider-hours, so traffic is never the limit.
- **Capacity (est.):** one CX23 (2 shared vCPU, 4 GB) should hold **~200 concurrent 8-rider races (~1,600 riders, ~3,200 msg/s in)**, with memory and CPU as the limit, not traffic. B3 confirms it.
- **Monthly:** the CX23 is **€5.99 ex VAT (€5.49 + €0.50 IPv4), ≈ €7.25 with 21% BE VAT**, flat whether 10, 100 or 1000 riders. Backups aren't needed (stateless; config in git). Domain ~€10–15/year (est.) or a free DNS subdomain. Above ~1,600 concurrent: CX33 €8.49 + €0.50. **Host-run and Quick Tunnel: €0.**

## Libraries
- [ ] **L1 P0 · Server:** `axum` (feature `ws`, uses tokio-tungstenite under the hood), `tokio`, `serde`/`serde_json`/`rmp-serde`, `rand` (codes/tokens), `tower_governor` (per-IP limits), `tracing` (no IP fields), Caddy for TLS. Build a static musl binary and run it as a systemd unit.
- [ ] **L2 P0 · Client networking in Rust:** `tokio-tungstenite` with `rustls-tls-webpki-roots` (no OpenSSL runtime dependency in the AppImage/Inno builds) in `rust/src/net/`. FRB API: `race_create`, `race_join`, `race_ready`, `race_send` (internal 2 Hz loop), `race_snapshot()` polled by the existing 250 ms timer (or a `StreamSink` later). Fallback if FRB gets in the way: `web_socket_channel` in Dart.
- [ ] **L3 P1 · Deep links:** `app_links` ^7.2.2 (Linux + Windows custom schemes verified in its README; needs the runner changes in J3).

## Open-source references (checked on GitHub 2026-10-08; GPL/AGPL = ideas only, don't copy code into this MIT repo)
- [zoffline/zwift-offline](https://github.com/zoffline/zwift-offline) (AGPL-3.0): a self-hosted partial Zwift server with opt-in multiplayer. A precedent for "run your own server" (option 2) and its port-opening pain (TCP 80/443/3025, UDP 3024).
- [masonwyatt23/globeride](https://github.com/masonwyatt23/globeride) (MIT): room codes with **no backend and no accounts**, a 4-peer WebRTC mesh, a binary state codec at 10 Hz. It shows the room-code UX and the mesh ceiling.
- [wolfv/cycling-workout](https://github.com/wolfv/cycling-workout) (no licence, read only): P2P group sessions with a **synchronized countdown start**, plus Cloudflare Durable Object signalling.
- [emperor-hadrian/virtual_bike](https://github.com/emperor-hadrian/virtual_bike) (GPL-3.0, Rust/Bevy/Renet): **server-side physics for path-bound riders**, the same model as the server owning distance along the route.
- [dvmarinoff/Auuki](https://github.com/dvmarinoff/Auuki), [GoldenCheetah](https://github.com/GoldenCheetah/GoldenCheetah): no multiplayer in their READMEs; useful for trainer and metrics UX only.

## Out of scope (later, optional)
Accounts and login, global or per-route leaderboards, persistent profiles and friends lists, stored race history server-side, Strava/intervals.icu posting of results (step 4 handles local upload), drafting (CdA × 0.7 within 2–10 m), spectators, a public room browser, bots/pacers from ghosts, async ghost sharing via `.tdshare` files. See the v1 file for the accounts design if it's ever needed.

## Top 5 for Build
1. **Prerequisites:** Pro-polish RM1 + RI2 (lat/lon + route key v2 in `gpx.rs`), plus the trim function producing the **canonical race route**.
2. **`race-physics` + `race-proto` shared crates:** power→speed model with golden tests, protocol enum (JSON + MessagePack round-trip).
3. **`server/` axum relay:** in-memory rooms, code/token, lobby→countdown→2 Hz snapshot→finish→results, 60 s resume → DNF, idle cleanup, sanity flags, no IP logs. Plus the `bot` load test (200×8 on a CX23).
4. **Client Race screen:** Create/Join with code + nickname, lobby/ready, synced 3-2-1, live gaps on the elevation profile/map, results. Networking in Rust over FRB. Demo hides Race.
5. **Deploy + polish:** Hetzner CX23 (FSN/NBG) + Caddy + privacy note. Then P1: `tacxdesktop://` links (app_links + .desktop/Inno registry) and "Host on this PC" LAN fallback.
