# Tacx Desktop roadmap

Direction (Niels, Oct 2026): **professional and simple**, closer to
TrainerRoad / Wahoo SYSTM / Garmin than to a Zwift-alike. **Garuda Linux is the
primary target**, Windows second. Background and scoring:
[`plan-pro-fun-3d.md`](plan-pro-fun-3d.md).

Rules for every step: widget/unit tests, `flutter analyze` clean, CI green on
`main`, clear commit messages. Keep Focus mode, Kickr/FTMS + Tacx FE-C,
**Demo OFF by default** and the existing charts working. Tick the box and record
the SHA here when a step lands.

**Current step:** 3 — Pro polish (design tokens → offline RouteMap →
ride summary). Ghost QA (cycle 2 G1–G9) and Research route-key v2 land
first; checklists in [`pro-polish.md`](pro-polish.md) and
[`multiplayer.md`](multiplayer.md).
**Last SHA:** see Log

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
      secrets in the repo), FTP test + auto FTP, GPX segment PRs ("KOMs"),
      streaks / badges (tasteful, local).
- [ ] **5. Multiplayer** — async first (exchange ghost files with friends), live
      later only if there is a clear need.

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
| 2b. Ghost QA + route key v2 + .tdshare | in progress | — | — |
