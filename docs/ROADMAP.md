# Tacx Desktop roadmap

Direction (Niels, Oct 2026): **professional and simple**, closer to
TrainerRoad / Wahoo SYSTM / Garmin than to a Zwift-alike. **Garuda Linux is the
primary target**, Windows second. Background and scoring:
[`plan-pro-fun-3d.md`](plan-pro-fun-3d.md).

Rules for every step: widget/unit tests, `flutter analyze` clean, CI green on
`main`, clear commit messages. Keep Focus mode, Kickr/FTMS + Tacx FE-C,
**Demo OFF by default** and the existing charts working. Tick the box and record
the SHA here when a step lands.

**Current step:** 3 — Pro polish. Done: design tokens (`3ac394f`), offline
route map with dot-only repaint (`06561a9`), Rust `ride_summary`
(NP / IF / TSS, mean-max 5 s–20 min, zones; `641e816`), status bar (`284902b`).
**Next:** link-health status bar → map/chart cursor split (OM1–OM3,
[`offline-map.md`](offline-map.md)) → post-ride summary screen (Save TCX /
Done, DEMO tag) → subtle motion (reduced-motion aware). Step 3 is ticked
only when all of that is on `main` with green CI.
**Last SHA:** `284902b`

## Steps

- [x] **1. Pro workout view** (`d40f621`) — planned workout as zone-coloured blocks
      (height = target W / %FTP, width = duration), actual power drawn over it,
      "now" cursor, current/next step strip, 3-2-1 countdown before step
      changes. Dashboard + Focus. Flutter only.
- [x] **2. Ghost race** (`155eeba`) — best attempt per GPX route (time vs distance) saved
      locally next to the workouts; live "+/- vs best" chip and a ghost marker
      on the elevation profile.
- [ ] **3. Pro polish** — design tokens (spacing, radii, zones, tabular
      digits), always-visible status bar, calm Focus layout, post-ride summary
      (NP, time in zone, best efforts), offline route map (lat/lon in FRB).
- [ ] **4. Fun extras** — Strava / intervals.icu upload (OAuth design first, no
      secrets in the repo), FTP test + auto FTP (from `best_20min_w`), GPX
      segment PRs ("KOMs"), streaks / badges (tasteful, local).
- [ ] **5. Mobile remote** — LAN web remote served by the desktop app, paired
      with a QR code; no accounts, no cloud. Spec:
      [`mobile-remote.md`](mobile-remote.md).
- [ ] **6. Online race mode** — room code + nickname; **no accounts, no users,
      no Supabase Auth / login, no database**; stateless relay. Reuses step 5's
      WebSocket envelope; the race relay never accepts control commands.
      Async `.tdshare` ghost exchange is a bonus inside this step. Spec:
      [`multiplayer.md`](multiplayer.md) (v2).

Design notes: engine pause / resume / skip and a `RideEnded` event serve both
the post-ride summary and step 5. One axum/WS envelope covers remote and race.

### Optional, later

- [ ] **3D / Blender "Scenic" view** behind a flag (`--dart-define=SCENIC=1`):
      `flutter_scene` spike or a separate Godot renderer; go/no-go on FPS on
      Niels' Garuda GPU. Not the main surface.

## Log

| Step | Status | SHA | CI run |
|------|--------|-----|--------|
| 0. Installers + v0.2.1 release | done | `fdb57de` (tag `v0.2.1`) | CI 37675496926, Release 37675940929 |
| 1. Pro workout view | done | `d40f621` | CI 37692811589 (success) |
| 2. Ghost race | done | `155eeba` | CI 37693301137 (success) |
| 2b. Ghost QA + route key v2 + .tdshare | done | `0ced1b4` `9e0c93f` `ccb2b7c` `2655760` `acdddb8` `4de468e` `e5787c4` `561fbaf` | CI 37694601586, 37695497136 (success) |
| 3. Pro polish | in progress | tokens `3ac394f`, map `06561a9`, ride_summary `641e816`, status bar `284902b` | CI 37695662694, 37695966929, 37696239863, 37696261690 (success) |
