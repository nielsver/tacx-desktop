# tacx-desktop: honest gap vs Zwift, plus the Pro / Fun / 3D plan

*Written 2026-10-07 (Brussels) against `main` @ `692b624` / release v0.2.1. Read-only audit; no code pushed.*
*For: Tacx Build. Scores are my own judgement, not measured stats.*

---

## 0. TL;DR

- **Verdict:** tacx-desktop is a solid **trainer controller and workout tool** (FTMS + FE-C over BLE, ERG/res/sim, workouts, GPX→grade, TCX, real installers). It has **no world at all**: no scene, avatar, map, route visual or other riders. Next to Zwift it's a different product class. On trainer control it's fine; on visuals and social it is roughly 0 to 1 out of 5.
- **Niels said "more professional is fine, simpler is OK".** So the **recommended path is Direction 1: Pro** (TrainerRoad / Wahoo SYSTM / Garmin-style) plus **2 or 3 cheap fun features** from Direction 2. 3D through Blender (Direction 3) is a **later optional "Scenic" view**, not the main surface.
- **First milestone (Pro M1):** a **Workout Ride view** with a target-vs-actual power graph and an interval timeline, using data the app already has (no Rust API change).
- **Blender on the box: works.** `apt install blender` gives Blender 4.3.2 at `/usr/bin/blender`. A headless smoke test exported a `.glb` and rendered Cycles (CPU), EEVEE and Workbench PNGs with no GPU (about 50 s for 3 renders at 640×360). Cycles needs `use_denoising=False` because the Debian build has no OIDN. Files are in `/workspace/blender-smoke/`.

---

## 1. What the visual layer is today (audit)

Files: `lib/src/ui/*.dart` (about 5.9k LOC, of which `ride_dashboard.dart` is 2.8k), `rust/src/trainer/*`.

- [x] **Design tokens exist:** `ride_theme.dart` has `RideColors` (dark bg `#0A0D11`, surfaces, per-metric colours) and the `RideType` type scale. A good base for Pro.
- [x] **Dashboard** (`ride_dashboard.dart`): metric cards, ERG/Resistance/Simulation panels, ride summary strip, reconnect banner, status strip. Polls Rust every **250 ms** with `Timer.periodic`.
- [x] **Focus / "game" mode** (`focus_ride_view.dart`): a large power number, cadence/speed/HR pills, a **radial gradient "zone wash"** tinted by power zone, a ≤2% cadence pulse, and an ERG dock. That is the whole "premium 2D visual". It has **no scene, no motion through space, no road and no rider.**
- [x] **Charts:** `live_trend_chart.dart` (`TrendPainter`: power/cadence/HR rolling lines, ERG target drawn **only as a flat guideline**) and `elev_profile_chart.dart` (`ElevPainter`: GPX elevation with a **progress marker**).
- [x] **Workouts** (`workout_panel.dart`): a list plus a simple ERG-step creator. **No planned-workout graph or interval timeline.** Full steps are available to Dart through `load_workout_json`.
- [ ] **Assets:** none. `pubspec.yaml` has no `assets:`, no fonts, no images. Deps are only `window_manager`, `shared_preferences` and FRB.
- [ ] **Map:** none. `gpx.rs` parses lat/lon, but `ElevSample` exposes only `distance_m`, `elev_m` and `grade_pct`.
- [ ] **Post-ride summary screen:** none. You get a summary strip and TCX export only.
- Note: speed is **trainer-reported wheel speed** (`ftms.rs`). There is no power→speed physics model. That matters for any "world" (virtual speed on a climb should drop with grade).

**Honest summary:** a clean, dark, functional control panel with one atmospheric effect. Visually it's in the same family as Auuki and an early TrainerRoad, not Zwift.

---

## 2. Competitive comparison (0–5, my judgement)

| Dimension | Zwift | MyWhoosh | Rouvy | TrainerRoad | TPV / Biketerra | Auuki / GoldenCheetah (OSS) | **tacx-desktop v0.2.1** |
|---|---|---|---|---|---|---|---|
| 3D world | 5 | 4 | video + AR (4) | 0 | 3–4 (GPX → 3D) | 0 | **0** |
| Avatar / customisation | 5 | 4 | 3 | 0 | 3 | 0 | **0** |
| Routes | 5 (fantasy worlds) | 4 | 5 (real video) | 0 | 4–5 (own GPX) | 0 / 1 | **2** (GPX→grade, no visual) |
| Multiplayer / events | 5 | 4 | 3 | 1 (group workouts) | 3 (bots fill fields) | 0 | **0** |
| Workouts | 4 | 4 | 3 | 5 (adaptive plans) | 4 | 4 (ZWO) / 4 | **3** (ERG/ramp/sim library) |
| Trainer control | 4 | 4 | 4 | 5 | 4 | 4 / 3 | **4** (FTMS + FE-C, reconnect) |
| Polish / UX | 5 | 4 | 4 | 5 | 3–4 | 3 / 2 | **2.5** |
| Linux native | no | no | no | no | no (Biketerra/Cycloscape = browser) | yes (browser) / yes | **yes, first-class (Garuda)** |
| Cost | paid sub | free | paid sub | paid sub | paid / freemium | free | **free, own app** |

Context (from 2026 comparison pages such as biketerra.com and cycloscape.com, not verified independently): Zwift reportedly acquired Rouvy (Apr 2026) and Garmin reportedly acquired TrainingPeaks (Jul 2026). TPV models drafting, cornering and braking. Biketerra, Cycloscape and TPV GPXplore turn your own GPX into 3D. **Open-source precedent:** `daruigh-wq/ride-sim` runs a separate **Godot 4** world process fed by BLE FTMS, with GPX→low-poly world baking and video sync. This is exactly "Option C" below, and proof a solo dev can do it. `qdomyos-zwift` has video sync and 2D/3D GPX maps.

**Gap, realistically:** the world, avatar, multiplayer and content gap to Zwift is years of team work and won't close. Where tacx-desktop *can* win: **native Linux**, no subscription, your own GPX, clean workout execution, and Tacx FE-C support. Compete with TrainerRoad and Auuki on UX, not with Zwift on worlds.

---

## 3. Three directions compared

| | **1. Pro (recommended)** | **2. Fun / gamified (no 3D)** | **3. 3D / Blender** |
|---|---|---|---|
| Look | TrainerRoad / SYSTM / Garmin: calm dark dashboard, big numbers, graphs | Ghost racing, PRs, XP, arcade/neon touches | Low-poly road + rider, GPX world |
| Effort (solo, Flutter + Rust) | **Low–Med** (Flutter `CustomPainter` + one small Rust change for map) | **Low–Med** per feature, they stack | **Med** (A: sprites) → **High** (B/C: real-time 3D) |
| Wow | Medium: "looks like a real product" | Medium–High for motivation | High at first sight, but weak if it's low quality |
| Fit with Garuda / Windows | **Excellent**: pure Flutter, no GPU risk | Excellent | A good. B needs Flutter ≥ 3.47.1 + Flutter GPU (Vulkan/GL driver risk on Linux). C adds a second binary to package |
| Risk | Low | Low (external APIs need OAuth secrets) | Medium–High (perf on iGPU, asset pipeline, packaging) |
| Uses existing code | Tokens, TrendPainter, ElevPainter, workouts JSON | Ride recording, TCX, GPX | GPX samples, speed, grade |

**Recommendation:** do **Pro first** (M1–M4), then add **ghost/PR racing + Strava upload** from Fun. Only after that, try **3D Option B (flutter_scene)** as an optional "Scenic" tab. Prefer pre-rendered Option A assets if you want visuals early without GPU risk.

---

## 4. Direction 1: Pro (recommended)

Design rules
- [ ] **Tokens:** extend `RideColors` / `RideType` with spacing (4/8/12/16/24), radii, elevation and **zone colours** (Z1–Z7, Coggan-style, from FTP). Add **tabular figures** (`FontFeature.tabularFigures()`) so numbers don't jitter. Optionally bundle one font (e.g. Inter / Roboto Mono for digits) under `assets/fonts`.
- [ ] **Calm dark:** one accent colour, zone colours only for power, no gradients behind numbers. Keep the zone wash as an opt-in only.
- [ ] **Motion:** 150–250 ms ease-out on value changes and step transitions only. Respect `disableAnimations`. Interpolate between 250 ms polls (lerp numbers, smooth graph scroll) so it feels 60 fps.
- [ ] **Status bar** (bottom, always visible): trainer ● name, mode (ERG/SIM/RES), HR strap ●, BLE signal, ride clock, recording ●. Reuse `ConnectionStatusIndicator` / `_StatusStrip`.

Ride screen layout (single screen, 16:9 and 1366×768 safe)
- [ ] **Top row of big metrics:** Power (3 s avg) | Target | Cadence | HR | Interval time left. The 3 s / 10 s smoothing is configurable.
- [ ] **Center: target-vs-actual power graph.** Planned workout as zone-coloured blocks (full workout, from `load_workout_json` steps), actual power line drawn over it, cursor at "now", ERG target line.
- [ ] **Interval timeline strip:** current step highlighted, "next: 4:00 @ 250 W" preview, step progress bar, 3-2-1 countdown at step changes.
- [ ] **GPX mode:** a **route map** (polyline + your dot) next to the **elevation profile + position** (existing `ElevPainter`), plus current grade %, distance done/left and next-climb preview.
- [ ] **Post-ride summary screen:** duration, distance, avg/NP/max power, avg HR/cadence, kJ, time-in-zone bars, power curve (5 s / 1 m / 5 m / 20 m bests), the graph again, and buttons for Save TCX / (later) Upload Strava / Discard.

Milestones
- [ ] **Pro M1 – Workout Ride view (first, ~1–2 days).** A new `WorkoutGraphPainter` (planned blocks + actual line + cursor) and an `IntervalTimeline` widget, fed by `load_workout_json` + `get_workout_status` + the existing metric history. Widget tests with fake samples, and a golden test for the painter. **No Rust change.** *Done when:* in demo mode, starting a built-in ramp workout shows the blocks, the live line follows, and the step countdown works.
- [ ] **Pro M2 – Tokens + status bar + big-metric row.** Refactor Focus to the calm layout. Keep the shortcuts (G / F11 / Esc).
- [ ] **Pro M3 – Post-ride summary.** Compute NP, zones and best-efforts in Rust (`ride.rs` already tracks samples) and expose them through FRB.
- [ ] **Pro M4 – Route map.** Add `lat`/`lon` to `ElevSample` (or a separate `track` vec) in Rust, regen FRB, and draw it with a `CustomPainter` (offline, no tiles). Add `flutter_map` + OSM tiles later only if wanted (mind the OSM tile usage policy and offline cache).

---

## 5. Direction 2: Fun without a full 3D world (ranked by fun ÷ effort)

| # | Idea | Fun | Effort | Notes |
|---|---|---|---|---|
| 1 | **Ghost / PR racing vs your own past rides** on the same GPX or workout | High | Low–Med | Rides are already recorded (TCX). Store per-distance time series, show "+12 s vs PR" and a ghost dot on the elevation/map |
| 2 | **Auto-upload to Strava / intervals.icu** | High (social proof) | Low–Med | Strava OAuth + upload API (needs a client secret, so use a loopback-redirect desktop flow). intervals.icu has an API key, simplest. Garmin Connect has no open upload API for individuals, so skip it |
| 3 | **Challenges:** FTP test (ramp / 20 min), climb "KOMs" on GPX segments, personal records board | High | Low–Med | The ramp workout exists. Auto-compute FTP and offer to set zones |
| 4 | **Streaks, XP, levels, badges** (local) | Med–High | Low | Local JSON. Badges for first 100 km, 10 h, a 4-week streak, FTP up. Keep it tasteful in the Pro style |
| 5 | **Video-route playback synced to speed** (your own GoPro MP4 + GPX) | High | Med | `media_kit` (libmpv) works on Linux and Windows and supports playback rate. Map distance→video time. Avoid YouTube: rate-manipulating embeds in a desktop webview is fragile and ToS-grey |
| 6 | **Coach / voice cues** ("30 s to go", "cadence up") | Med | Low | TTS: `flutter_tts` on Windows, speech-dispatcher on Linux. Or ship short pre-recorded clips (works everywhere) |
| 7 | **Power-driven mini-games** (keep a ball in a lane at target watts, "hold the zone" arcade) | Med–High | Med | Pure Flutter 2D (`flame` engine is optional). Great for ERG boredom |
| 8 | **Stylized 2.5D / retro-neon road** (synthwave grid road whose speed follows the trainer and tilts with grade) | Med–High | Low–Med | `CustomPainter` pseudo-3D road (classic OutRun technique). A 3D feel without 3D. Bridges into Direction 3 |
| 9 | **Async multiplayer: friends' ghosts** | High | Med–High | Needs file sharing (exchange a ghost file; no server at first) |
| 10 | **Unlockable kits/bikes** | Low–Med | Med–High | Only meaningful once an avatar exists (Direction 3) |
| 11 | **Music/BPM sync** | Low–Med | Med–High | Platform media APIs differ (MPRIS on Linux, SMTC on Windows). Low value |

**Top 5:** (1) ghost/PR racing, (2) Strava / intervals.icu upload, (3) FTP test + GPX segment PRs, (4) streaks/XP/badges, (8 or 5) retro road *or* video sync.
**Quick win:** **PR / ghost delta on a GPX route.** On finishing a route, save `(distance_m, elapsed_s)` samples. On the next ride of the same GPX (hash it), show a live "+/-mm:ss vs PR" chip and a ghost marker on the elevation profile. About 1 day, fits the Pro look, and needs no network.

---

## 6. Direction 3: Zwift-like visuals with Blender

**Option A: pre-rendered Blender assets in Flutter (cheap, safe)**
- Parallax layers (sky, mountains, trees) + a road loop sprite-sheet + a rider pedalling sprite-sheet (e.g. 24 frames). Scroll speed = trainer speed, pedal frame rate = cadence, horizon tilt = grade.
- Pros: runs on any GPU via the normal Flutter renderer, small effort. Cons: on-rails, fixed camera, repetitive. It looks "indie 2.5D", not Zwift.
- **Headless CI works:** `blender -b -P render_sprites.py` with EEVEE or Cycles CPU (`use_denoising=False` on the Debian build). Commit the `.blend` + script, and render to `assets/` in a CI job or locally.

**Option B: real-time 3D inside Flutter (glTF from Blender)**
- **`flutter_scene`** (Flutter GPU + Impeller): glTF, PBR, skinned animation, physics. Officially supports **Linux + Windows** and needs **Flutter ≥ 3.47.1** for desktop release builds, plus `fl_dart_project_set_enable_flutter_gpu(project, TRUE)` in `linux/runner/my_application.cc` and `project.set_enable_flutter_gpu(true)` in `windows/runner/main.cpp`. Impeller became the desktop default in 3.47 (Aug 2026). The Scene Editor 0.24.0 (5 Oct 2026) is the first with Linux and Windows builds. **Verdict: usable but new.** Expect driver issues on some Linux GPUs and keep a 2D fallback. CI uses `flutter-action` channel `stable` unpinned, so check that the built version is ≥ 3.47.1 and pin it.
- **Rust wgpu/Bevy into a Flutter texture** (`flutter_wgpu_texture`: D3D12 on Windows, Vulkan/DMA-BUF on Linux): powerful but young plumbing, and integrating with FRB is harder. Not for a solo first step.
- `three_dart` / filament wrappers: stale or mobile-first on desktop. Skip.

**Option C: separate renderer (Godot 4 or Bevy) driven by the Rust core over local IPC**
- Rust core streams `{speed, cadence, power, grade, distance}` at 20–60 Hz over a Unix socket on Linux or a named pipe on Windows (JSON or bincode). The renderer runs in its own window (or fullscreen on a second monitor).
- Pros: a real game engine (Godot 4 has a mature Linux/Windows exporter and editor, and imports glTF from Blender natively), the best visual ceiling, and the Flutter app stays stable. **Precedent: ride-sim (Godot 4 world + Python BLE).**
- Cons: two apps to package (AppImage/.deb/Inno must bundle the Godot export, roughly 60–100 MB), two UIs, and you can't embed it in the Flutter window on Wayland.

**3D pick:** **Option B (`flutter_scene`)** if Flutter ≥ 3.47.1 + Flutter GPU proves stable on Niels' Garuda GPU, because it's one app and one UI. **Fallback: Option C (Godot)** if Flutter GPU misbehaves on Linux. Use Option A sprites for the Pro/Fun "scenic header" in the meantime.

**3D milestone 0 (tiny, behind a flag):**
- [ ] Spike branch: bump and pin Flutter ≥ 3.47.1, add `flutter_scene`, enable Flutter GPU in both runners, add a `ScenicView` widget behind `--dart-define=SCENIC=1`.
- [ ] Load `road_rider.glb` (Blender: a 200 m road tile + low-poly rider, about 2k tris). Loop the road tile with Z-offset driven by `speedKmh`, spin the wheels by speed, and pitch the camera by `routeStatus.gradePct` (clamped ±10°).
- [ ] Measure FPS on Niels' Garuda machine plus one Windows iGPU. *Go/no-go:* ≥ 50 fps at 1080p and no crash on the AppImage. Otherwise fall back to Option C or A.
- [ ] Later: add a power→speed physics model (mass, CdA, Crr, grade) in Rust so virtual speed isn't raw trainer wheel speed. Generate GPX → terrain strip meshes (Rust or a Blender script) and build a Blender asset kit (trees, barriers, kit colours).

---

## 7. Blender availability and CI

- [x] Box (Debian 13): `sudo apt install blender` gives **Blender 4.3.2**. The first attempt hit a mirror 500 error; `apt-get update` + `--fix-missing` fixed it.
- [x] Headless smoke (`/workspace/blender-smoke/smoke.py`): procedural road + trees + rider block → `road_rider.glb` (25 KB) + `cycles.png` / `eevee.png` / `workbench.png`. **EEVEE also rendered with no GPU.** Cycles: set `scene.cycles.use_denoising = False` (no OIDN in the Debian build).
- Garuda (Niels): `sudo pacman -S blender` (Arch extra, current Blender), or Flatpak `org.blender.Blender`, or the official tarball. Windows: installer / winget `BlenderFoundation.Blender`.
- CI: on `ubuntu-24.04` use `apt install blender` (older version) or, better, download the official Linux tarball for a pinned version + cache. Then `blender -b assets_src/scene.blend -P tools/render_sprites.py`. Keep renders small (CPU only). Commit the outputs, or attach them as artifacts and copy them in at release time.

---

## 8. Hand-off checklist for Tacx Build (in order)
1. [ ] **Pro M1:** `WorkoutGraphPainter` + `IntervalTimeline` (no Rust change) + tests. Report the SHA.
2. [ ] **Quick win:** GPX PR/ghost delta chip + ghost marker on the elevation profile.
3. [ ] **Pro M2:** tokens (spacing, zones, tabular digits), status bar, calm Focus layout.
4. [ ] **Pro M3:** post-ride summary (NP, zones, best efforts in Rust).
5. [ ] **Pro M4:** lat/lon in FRB + offline route map painter.
6. [ ] Strava or intervals.icu upload (OAuth design first; no secrets in the repo).
7. [ ] Optional: 3D milestone 0 spike (`flutter_scene`, flag-gated), go/no-go on FPS.
