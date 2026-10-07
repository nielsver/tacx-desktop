# tacx-desktop: multiplayer design checklist (roadmap step 5)

*Written 2026-10-08 (Brussels) against `main` @ `155eeba` (step 2 ghost race). Read-only research; no code, PRs or commits.*
*For Tacx Build. Prices were checked on 2026-10-08 and exclude VAT. Anything marked **(est.)** is my estimate, not a quote.*

## 0. TL;DR and what we reuse
- **Recommended backend:** Phase A = **file share first, then Supabase (EU Frankfurt: Auth + Postgres + Storage)**. Phase B = **a self-hosted Rust/axum WebSocket relay on a Hetzner CX23** that checks Supabase JWTs. Supabase Realtime is fine for a prototype only (see §3).
- **Reuse:** `route_ghost.dart` already has everything a friend ghost needs. `GhostTrack` is `(d,t)` only, so it holds **no GPS**. `timeAt`/`distanceAt`, `ghostDeltaS`/`fmtDelta`, `GhostStore` (atomic tmp+rename) and the ghost marker in `ElevPainter` all carry over. Multiplayer = "more ghosts, some of them live".
- **Gaps to close first:** (1) `routeKey` is FNV over the rounded elevation profile. A GPX without `<ele>` (allowed: see the `gpx.rs` test) hashes to all zeros, so **two flat routes with the same rounded distance and sample count collide**. (2) `ElevSample` has no lat/lon (`gpx.rs` parses them but doesn't expose them). (3) Route progress = **trainer-reported wheel distance** (`controller.rs`, `ride::stats().distance_km`), so a Kickr and a Tacx are not comparable. Demo mode also creeps at 5 m/s.
- **Golden rule:** networking is an **overlay**. A network failure must never touch trainer control, ERG/SIM or local recording.

## 1. Phase A: async ghosts of friends
- [ ] **P0 · Route key v2.** `routeKeyV2 = sha256("v2|" + round(distM/10) + 64 points resampled evenly by distance, each as (lat,lon) rounded to 1e-4 (~11 m) + elev rounded to 1 m)`, hex, first 16 bytes. Compute it in Rust (`gpx.rs`) **on the canonical shared route** (after privacy trimming, §6), so sender and receiver hash the same points. Keep v1 as an alias: `GhostStore` looks up v2 first, then v1. *Done when:* two different flat no-`<ele>` GPX files give different keys; the same GPX re-exported (different name/timestamps/point density ±10%) gives the same key; there are unit tests for both.
- [ ] **P0 · lat/lon in FRB** (this is also step 3, Pro M4). Add `lat`/`lon` to `ElevSample` or a separate `track` vec. *Done when:* Dart can draw the map and compute v2 without re-parsing.
- [ ] **P0 · Share bundle `.tdshare` (no backend).** Gzipped JSON `{v:1, kind:"ghost", routeKeyV2, routeKeyV1, routeName, distanceM, totalS, track{d[],t[]}, route{samples:[d,elev,lat,lon]} (trimmed), rider{displayName}, app:"0.x", verified:false, demo:false, createdDate}`. **No HR, no weight, no wall-clock timestamps** (date only). Export from the post-ride summary; import with a file picker or drag-drop. Max 1 MB, strict parse like `GhostTrack.fromJson`. *Done when:* a friend imports the file, the route loads, and both ghosts (own best + friend) race on the profile.
- [ ] **P0 · Exclude Demo rides.** `AttemptRecorder` attempts made in Demo get `demo:true` and are never exportable or "verified". *Done when:* there's a test showing a Demo attempt can't be exported.
- [ ] **P1 · Multi-ghost UI.** Up to 5 ghosts (own best = violet, friends = a neutral palette plus initials), a chip per ghost (`+0:12 Jan`), toggles in the Workouts panel. Store friends' ghosts in `routes/ghosts/<key>.<friendId>.json`. *Done when:* 3 ghosts render at 60 fps in Focus on Garuda.
- [ ] **P1 · Upload + share code (Supabase).** Table `ghosts(id, owner, route_key_v2, total_s, track jsonb, created)`, table `routes(key_v2, samples, dist_m, owner)`, and Storage for big blobs. Share by a **short code** (`K7QX-92`) typed in the app. Avoid deep links: `x-scheme-handler` registration differs by Linux packaging. *Done when:* code → download → ride works, and RLS blocks reading a non-shared ghost.
- [ ] **P2 · Friends list + "beat my time" leaderboard per route** (friends only, no public leaderboards in v1).

## 2. Phase B: real-time group ride
- [ ] **P0 · Virtual speed in Rust.** Add a physics model in the core: power + grade(d) + mass + CdA + Crr give speed, which gives `d`. Use the same function on the server (shared `tacx-proto` crate). This replaces wheel speed for MP rides and is the basis for fairness and anti-cheat. *Done when:* the same power file gives the same `d` on Tacx, Kickr and Demo (±1%).
- [ ] **P0 · Position = distance along the canonical route** (1D `d_m`). Map position comes from `d` plus the route polyline. **No GPS is ever sent.**
- [ ] **P0 · Rates.** The client sends `state` at **2 Hz** by default (1 Hz when the window isn't focused, 4 Hz cap). The server batches one `snapshot` per room at 2 Hz. *Done when:* a 20-rider room stays under 1 KB/s down per client.
- [ ] **P0 · Latency.** Clock offset comes from `ping/pong` (NTP-style: keep the sample with the lowest RTT out of the last 5). Render other riders at `serverNow − 600 ms`, interpolating between snapshots. **Extrapolate** up to 2 s with the last speed, then freeze and grey the marker. Your own rider is always local and never waits on the network. *Done when:* with a 200 ms jitter netem test, markers move smoothly with no backwards jumps.
- [ ] **P0 · Rooms, join, leave.** Private rooms only in v1: a 6-character room code bound to `routeKeyV2`, max 20 riders. The host clicks Start, the server sends `start_at` (server time), and there's a 10-s countdown. Late joiners start at d=0 and are tagged `late` (excluded from results). *Done when:* 3 clients start within 100 ms of each other.
- [ ] **P0 · Disconnect.** With no `state` for 3 s, the server marks the rider `stale` (grey). After 60 s it drops them (`rider_left{reason:"timeout"}`). The client reconnects with backoff (1, 2, 4, 8, max 15 s) and resumes with `resume{room, last_d}`. The local ride and recording keep going; the banner reuses the existing reconnect banner style. *Done when:* pulling the network for 20 s mid-ride → automatic rejoin, ERG unaffected.
- [ ] **P1 · Results.** The server records finish time per rider when `d ≥ dist`, shows a room results card, and saves to Supabase (service key on the server only).
- [ ] **Drafting: NO for v1.** **P2** later: a simple rule. Within 2–10 m behind another rider, use CdA × 0.7 in the virtual-speed model, and in SIM mode also send a lower `cw` to the trainer. ERG mode doesn't change. Make it a room setting, default off.
- [ ] **P2 · Group workout mode** (wolfv-style): the host shares a workout, everyone rides it at their own %FTP, with a synced start. No positions needed.

## 3. Backend options for a solo dev
| | Effort | €/month | Scaling limit | EU residency | Lock-in |
|---|---|---|---|---|---|
| **Rust/axum WS on Hetzner** | Med: you run TLS (Caddy), backups, updates | CX23 €5.49 + IPv4 €0.50, 20 TB traffic | One small box handles thousands of idle WS (est.); shard rooms later | DE/FI, German company | None |
| **Supabase** (Auth/DB/Storage/Realtime) | Low for auth and data | Free $0 (pauses after 1 wk inactivity, 200 RT conns); Pro $25 incl. 500 conns + 5 M msgs, then $2.50/M | Pro: **500 msg/s**, and every *delivered* message counts | Frankfurt/Paris/Stockholm/Ireland (AWS, US parent → SCCs/DPA) | Low–Med: Postgres is portable, self-hostable |
| **Firebase** | Low on mobile, **bad on Linux**: FlutterFire Linux/Windows desktop is development-only | RTDB $5/GB stored, $1/GB down | RTDB 200k conns/DB | RTDB in europe-west1 (Belgium) | High (proprietary NoSQL) |
| **P2P / WebRTC** | High: signalling + TURN, NAT pain | ~€0 + TURN relay (est.) | Mesh ~4–8 peers (globeride caps at 4) | Depends on TURN host | Low, but **no server authority** → no anti-cheat |
- **Pick:** Phase A = **Supabase EU (Frankfurt)**, so you don't hand-roll auth; a file-only A1 needs no backend at all. Phase B = **axum relay on Hetzner (FSN/NBG)**. Server-side checks sit in the hot path, cost is flat, and the Rust code is shared with the core.
- **Why not Supabase Realtime for B:** a room of 8 at 2 Hz = 16 sent + 112 delivered = **128 msg/s**, so 4 rooms hit the Pro 500 msg/s cap. At 1000 riders it's ~276 M msgs/mo ≈ **$700/mo (est.)**. And there's nowhere to run plausibility checks.

## 4. Identity and auth
- [ ] **P0 · Supabase Auth email OTP (6-digit code typed in the app).** No redirect, no deep link, no loopback, so it works the same on Garuda and Windows. Built-in email is **2/hour, test only**: plug in an EU SMTP (Brevo free tier 300/day). *Done when:* sign-in works on both OSes with no browser handoff.
- [ ] **P0 · Token storage.** `flutter_secure_storage` (11.x) uses **libsecret** on Linux and, on Windows, an AES-GCM file whose key lives in **Credential Manager**. Give supabase_flutter a custom `LocalStorage` on top of it, never SharedPreferences. Add `libsecret` to Garuda/AUR/.deb deps. Test on KDE (KWallet Secret Service, or gnome-keyring). If no keyring exists: re-login each launch, **never plaintext**. Dart owns refresh; it passes the short-lived access JWT to Rust on `mp_connect`.
- [ ] **P0 · Relay verifies JWTs locally** via `https://<ref>.supabase.co/auth/v1/.well-known/jwks.json` (asymmetric signing keys; cache it, it's edge-cached 10 min). Check `iss`, `aud=authenticated`, `exp`.
- [ ] **P2 · Google OAuth** via PKCE + loopback (`http://127.0.0.1:<random>/cb`, system browser). **Do not use Strava as identity**: its API policy §2.3 allows Strava data to be shown only to that same user, so friends couldn't see names or rides. Strava stays upload-only (step 4).

## 5. Anti-cheat basics (honest: a modded client can always lie)
- [ ] **P0 · Server plausibility per `state`:** `d` must be monotonic. `Δd/Δt ≤ 25 m/s` (also ≤ physics speed(p, grade) + 15%). `p ≤ 2500 W`. Rolling W/kg ceilings (5 s > 25, 1 min > 12, 5 min > 8, 20 min > 6.5) and cadence 0 with p > 300 W for > 5 s → flag. `seq` gaps or out-of-order → drop. *Done when:* replaying tampered fixtures sets flags.
- [ ] **P0 · Verified vs unverified.** `verified` = a live server-observed ride with no flags, not Demo, not late. Imported or uploaded ghost files are **always unverified** (show a "file" badge). Weight comes from the user and is kept in RAM only.
- [ ] **P0 · Rate limits:** ≤ 5 msg/s per connection (else kick), ≤ 10 joins/min per user, ≤ 50 uploads/day, ≤ 1 MB per file, 20 riders/room (`tower_governor`).
- [ ] **P1 · Social controls:** friends-only rooms, host kick, report/block. No public leaderboards until P2.

## 6. Privacy and GDPR (Belgium/EU)
- [ ] **P0 · Lawful basis:** contract (Art. 6(1)(b)) for account + MP; consent (6(1)(a)) for optional extras. **HR is health data (Art. 9)**: v1 **never uploads HR**. If it's ever added: explicit opt-in (9(2)(a)), off by default, plus a DPIA. Treat weight as sensitive too: RAM only, never shown.
- [ ] **P0 · No home-location leak.** Shared routes are **trimmed 500 m at start and end** (setting 200–1000 m), with GPX metadata (time/author/device/name) stripped. Offer built-in **virtual routes** (curated GPX not tied to anyone's home). Live MP sends only `d`, never lat/lon. *Done when:* a test shows the exported route's first and last points are ≥ the trim distance from the original.
- [ ] **P0 · Retention:** live positions in RAM only. Server logs ≤ 14 days with truncated IPs. Ghosts/routes kept until deleted, and accounts deleted after 12 months of inactivity (warning email first). Supabase backups roll off at 7 days.
- [ ] **P0 · Rights:** in-app **Export my data** (JSON zip) and **Delete account** (cascade rows + storage objects). Answer requests within 1 month (Art. 12(3)).
- [ ] **P0 · Paperwork:** privacy policy (NL + EN) naming the processors (Supabase, Hetzner, Brevo) and their DPAs (accept them in each dashboard); a light Art. 30 record; breach notification to the **Gegevensbeschermingsautoriteit / APD** (gegevensbeschermingsautoriteit.be) within 72 h; minimum age 13 (BE digital consent age); EU hosting only.

## 7. Monthly cost estimate (recommended path, ex VAT; BE VAT 21% if billed as a private person)
Assumptions **(est.)**: 16 ride-h per rider per month, 30% of them in groups, rooms of 8, 2 Hz, a ghost file ≈ 15 KB gz.
| Riders | Supabase | Hetzner relay | Other | Total |
|---|---|---|---|---|
| 10 | Free $0 (friends beta; accepts pausing) | CX23 €5.49 + IPv4 €0.50 | domain ~€1 (est.), Brevo free | **≈ €7** |
| 100 | Pro $25 (≈ €22, est.): no pausing, backups | CX23 €5.99 + backups €1.10 | ~€1 | **≈ €30** |
| 1000 | Pro $25, still within quotas (ghosts ≈ 0.25 GB/mo) | CX33 €8.49 + IPv4 €0.50 + backups €1.70, optional standby CX23 €5.99 | ~€1 | **≈ €35–45** |
Relay traffic at 1000 riders ≈ 7 GB/mo (est.) vs 20 TB included. The same B load on Supabase Realtime ≈ $82/mo at 100 riders and ≈ $700/mo at 1000 (est.).

## 8. Libraries (networking in Rust, behind the existing FRB 2.13 bridge)
- **Core (`rust/src/net/`):** `tokio-tungstenite` (`rustls-tls-webpki-roots`: no OpenSSL runtime dep in the AppImage/Inno builds) on the existing tokio runtime; `serde` + `rmp-serde` (MessagePack, named fields; JSON behind a debug flag). FRB API: `mp_connect(url, jwt)`, `mp_join(code, route_key)`, `mp_peers() -> Vec<PeerState>` polled by the existing 250 ms timer (or an FRB `StreamSink` later).
- **Shared crate `proto/` (`tacx-proto`):** message enums + the physics fn, used by both the core and the server.
- **Server:** `axum` (feature `ws`), `tokio`, `jsonwebtoken` (ES256/JWK), `tower_governor`, `tracing`, `reqwest` for writing results to Supabase; Caddy for TLS; a systemd unit; Hetzner backups.
- **Dart:** `supabase_flutter` (auth/postgrest/storage), `flutter_secure_storage`, `file_selector` for `.tdshare` import/export. Skip `web_socket_channel`: the socket lives in Rust.

## 9. Open-source references (checked on GitHub 2026-10-08)
- [zoffline/zwift-offline](https://github.com/zoffline/zwift-offline) (AGPL-3.0): a partial Zwift server with opt-in multiplayer. It stores **ghosts per route** (`storage/<player>/ghosts/<world>/<route>`) and replays ghosts as **bots/RoboPacers** (recorded at 1 s). Good model for ghost storage and pacer bots.
- [wolfv/cycling-workout](https://github.com/wolfv/cycling-workout) (**no licence: read only**): a browser FTMS app with **P2P group sessions**, a host-shared workout scaled to each rider's FTP, a synced countdown start, and Cloudflare Durable Object signalling. The template for "group workout".
- [masonwyatt23/globeride](https://github.com/masonwyatt23/globeride) (MIT): a browser GPX sim with **WebRTC mesh of up to 4 peers via room codes**, a binary state codec at 10 Hz, signed P2P race manifests, and drafting with peers. Shows the mesh ceiling and the room-code UX.
- [emperor-hadrian/virtual_bike](https://github.com/emperor-hadrian/virtual_bike) (ex-HDrizzle, GPL-3.0, Rust/Bevy): client/server over Renet, **path-bound riders on splines with server-side physics**. This matches our server-authoritative distance-along-route model.
- [dvmarinoff/Auuki](https://github.com/dvmarinoff/Auuki) (AGPL-3.0) and [GoldenCheetah](https://github.com/GoldenCheetah/GoldenCheetah) (GPL-2.0): **no multiplayer** in their READMEs. Useful for workout UX and metrics only. [cagnulein/qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift) (GPL-3.0) is a device bridge, not multiplayer.
- The GPL/AGPL projects are for ideas only. Don't copy their code into this MIT repo.

## 10. Message protocol sketch (v1, MessagePack over WSS, `{"type":…}`-tagged serde enum)
```
C→S hello   {v:1, jwt, app_ver}                         S→C welcome {user_id, server_ms}
C→S create  {route_key_v2, dist_m, profile:[d,elev]}     S→C created {room_code}
C→S join    {room_code, route_key_v2, mass_kg}          S→C joined  {room, roster:[{id,name}], state:"lobby"|"running", start_at_ms?}
C→S start   {}  (host only)                             S→C start   {start_at_ms}
C→S state   {seq, client_ms, d_m, v_mps, p_w, cad}      S→C snapshot{server_ms, riders:[{id, d_m, v_mps, p_w, flags}]}  (2 Hz)
C→S resume  {room_code, last_d_m}                       S→C rider_joined{id,name} · rider_left{id, reason:"leave"|"timeout"|"kick"}
C→S ping    {client_ms}                                 S→C pong    {client_ms, server_ms}
C→S leave   {}                                          S→C finish  {id, total_s, verified} · error{code, msg}
```
Rules: the server rejects a `join` when the route key doesn't match; `profile` is d/elev only (no lat/lon) so the server can check grades; unknown `v` → `error{code:"upgrade"}`.

## 11. Phased recommendation
1. **MP0 (alongside step 3):** lat/lon in FRB, `routeKeyV2`, Demo flag, virtual-speed model in Rust.
2. **MP-A1:** `.tdshare` export/import + multi-ghost UI. No backend; ship it to 2–3 friends.
3. **MP-A2:** Supabase EU (OTP login, share codes, export/delete, privacy policy).
4. **MP-B1:** axum relay, private rooms, 2 Hz, interpolation, sync start, disconnect handling. No drafting.
5. **MP-B2:** plausibility flags, verified results. **P2:** drafting, bots from ghosts, group workouts, public events.

## Top 5 ordered actions
1. Land **`routeKeyV2`** (64-point lat/lon/elev + distance, computed on the trimmed canonical route) plus **lat/lon in FRB**. Keep v1 as an alias.
2. Ship **`.tdshare` export/import + multi-ghost** (no backend, no HR/GPS endpoints, Demo excluded).
3. Add the **Rust virtual-speed model** in a shared `tacx-proto` crate (fairness + anti-cheat basis).
4. Stand up **Supabase EU Frankfurt**: email OTP via Brevo SMTP, RLS, Storage, export/delete, NL/EN privacy policy.
5. Build the **axum WSS relay on a Hetzner CX23** (Caddy, JWKS checks, protocol v1 at 2 Hz, interpolation) and soak-test it with 50 bot clients.
