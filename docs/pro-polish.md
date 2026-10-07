# tacx-desktop step 3 "Pro polish": map, tokens, summary, route identity
*2026-10-08 (Brussels). Read-only audit of `main` @ `155eeba` (HEAD; `bc64814` is an older CI fix). No code pushed.*
*Found: no lat/lon in FRB (`ElevSample` = distance/elev/grade); `RideColors`/`RideType` consts, no ThemeExtension; `kZoneColors` + `powerZone()` in `workout_plan.dart`; `RideStats` has avg/max power, avg cad, kJ, km, avg/max HR (no NP, max cad, zones); 1 Hz `TrackPoint`s in `ride.rs`; TCX export exists; `routeKey()` = FNV-1a over (distance, elev×10) samples.*

## Route map. Pick (a): CustomPainter, offline, no tiles
| | (a) CustomPainter | (b) flutter_map 8.3.2 + OSM tiles |
|---|---|---|
| Deps / licence | none | flutter_map is BSD-3 (fine). The offline plugin flutter_map_tile_caching 10.1.1 is **GPL-3.0** (clashes with the repo's MIT unless you buy a licence) and pulls in a native ObjectBox lib |
| OSM policy | n/a | Needs a unique UA (`userAgentPackageName: 'com.nielsver.tacx_desktop'`), visible "© OpenStreetMap contributors", HTTP caching (built-in cache, 1 GB default). **No bulk or offline prefetch from tile.openstreetmap.org**, so "download route area" is banned. Make the tile URL configurable |
| Linux | nothing changes; works offline in a pain cave | network at runtime (blank map offline), cache dir under XDG, a few MB extra in the tar.gz/AppImage/.deb, more CI/test surface |
- [ ] **RM1 P0: lat/lon to Dart.** Add `lat`, `lon` to `ElevSample` (`types.rs`), filled in `gpx.rs::parse_gpx` (the same loop already skips <5 cm jitter, so distance stays aligned), then regen FRB. *Done:* `samples[i].lat/lon` in Dart; Rust test asserts first/last coords.
- [ ] **RM2 P0: `RouteMap` widget** (sketch below). Build `RouteGeo` **once per GPX load** in state (not in `build`). Path cached per size; only the dot layer repaints, driven by a `ValueNotifier<double>` (progress m) updated in the 250 ms `_refresh`. *Done:* golden test; DevTools "highlight repaints" shows only the dot flashing; rider and ghost dots sit on the line.
- [ ] **RM3 P1:** ghost dot (`ghostM`) on the map, start/finish markers, "done" segment tint, map placed next to `ElevProfileChart`. **P1 later:** flutter_map behind a setting, online only, never prefetching.
```dart
class RouteGeo { // pts need lat/lon (RM1)
  RouteGeo(this.pts); final List<ElevSample> pts;
  Size? _s; late List<Offset> xy; late Path path;
  void fit(Size s) { // equirectangular around centroid, fit bbox, y flipped
    if (s == _s) return; _s = s;
    final k = math.cos(pts.map((e) => e.lat).reduce((a, b) => a + b) / pts.length * math.pi / 180);
    final raw = [for (final e in pts) Offset(e.lon * k, -e.lat)];
    var r = Rect.fromPoints(raw.first, raw.first);
    for (final o in raw) { r = r.expandToInclude(Rect.fromPoints(o, o)); }
    final sc = 0.9 * math.min(s.width / math.max(r.width, 1e-9), s.height / math.max(r.height, 1e-9));
    final off = s.center(Offset.zero) - r.center * sc;
    xy = [for (final o in raw) o * sc + off];
    path = Path()..addPolygon(xy, false);
  }
  Offset at(double d) { // rider position by distance along route
    if (d <= 0) return xy.first; if (d >= pts.last.distanceM) return xy.last;
    var lo = 0, hi = pts.length - 1;
    while (hi - lo > 1) { final m = (lo + hi) >> 1; pts[m].distanceM <= d ? lo = m : hi = m; }
    final a = pts[lo].distanceM;
    return Offset.lerp(xy[lo], xy[hi], (d - a) / (pts[hi].distanceM - a))!;
  }
}
class RouteMap extends StatelessWidget {
  const RouteMap({super.key, required this.geo, required this.progressM});
  final RouteGeo geo; final ValueListenable<double> progressM;
  @override Widget build(BuildContext c) => Stack(fit: StackFit.expand, children: [
    RepaintBoundary(child: CustomPaint(painter: _Route(geo))),             // static path
    RepaintBoundary(child: CustomPaint(painter: _Dot(geo, progressM))),    // repaints at 4 Hz
  ]);
}
class _Route extends CustomPainter { _Route(this.g); final RouteGeo g;
  @override void paint(Canvas c, Size s) { g.fit(s); c.drawPath(g.path, Paint()
    ..style = PaintingStyle.stroke..strokeWidth = 3..strokeJoin = StrokeJoin.round..color = RideColors.accent); }
  @override bool shouldRepaint(_Route o) => o.g != g; }
class _Dot extends CustomPainter { _Dot(this.g, this.d) : super(repaint: d);
  final RouteGeo g; final ValueListenable<double> d;
  @override void paint(Canvas c, Size s) { g.fit(s); c.drawCircle(g.at(d.value), 6, Paint()..color = RideColors.power); }
  @override bool shouldRepaint(_Dot o) => o.g != g || o.d != d; }
```

## Design tokens
- [ ] **DT1 P0:** `AppTokens` ThemeExtension, registered in `buildRideTheme()` (`extensions: const [AppTokens()]`). Zones reuse `kZoneColors` + `powerZone()` (Coggan: <55/56–75/76–90/91–105/106–120/121–150/>150 %FTP) as the **single source**. *Done:* no hard-coded `EdgeInsets`/`circular(12)` in new or edited widgets; a test for `lerp(t=0/1)`.
- [ ] **DT2 P0:** tabular digits on every live number (power, HR, cadence, clocks, deltas). Today only `workout_ride_view` and one dashboard spot have them. *Done:* the 1→111 W digit width stays constant in a golden.
- [ ] **DT3 P1:** Focus glow switches from absolute-watt `powerZoneAccent()` to FTP zones (FTP is already persisted, default 200). Bundle one OFL font with `tnum` (e.g. Inter) so Garuda font fallback can't drop tabular figures.
```dart
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({this.space = const [4, 8, 12, 16, 24], this.rSm = 8, this.rMd = 12, this.rLg = 16, this.zones = kZoneColors});
  final List<double> space; final double rSm, rMd, rLg; final List<Color> zones; // Z1..Z7
  double get xs => space[0]; double get s => space[1]; double get m => space[2]; double get l => space[3]; double get xl => space[4];
  Color zoneFor(double w, int ftp) => zones[powerZone(w, ftp) - 1];
  @override AppTokens copyWith({List<double>? space, double? rSm, double? rMd, double? rLg, List<Color>? zones}) =>
      AppTokens(space: space ?? this.space, rSm: rSm ?? this.rSm, rMd: rMd ?? this.rMd, rLg: rLg ?? this.rLg, zones: zones ?? this.zones);
  @override AppTokens lerp(AppTokens? o, double t) => o == null ? this : AppTokens(
      space: [for (var i = 0; i < 5; i++) lerpDouble(space[i], o.space[i], t)!],
      rSm: lerpDouble(rSm, o.rSm, t)!, rMd: lerpDouble(rMd, o.rMd, t)!, rLg: lerpDouble(rLg, o.rLg, t)!,
      zones: [for (var i = 0; i < 7; i++) Color.lerp(zones[i], o.zones[i], t)!]);
}
extension TokensX on BuildContext { AppTokens get tk => Theme.of(this).extension<AppTokens>()!; }
const kTabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
// Text('$watts', style: TextStyle(fontSize: RideType.focusHero, fontWeight: FontWeight.w700).merge(kTabular))
// Padding(padding: EdgeInsets.all(context.tk.l)) … BorderRadius.circular(context.tk.rMd)
```

## Post-ride summary (minimum set)
- [ ] **PS1 P0 (Rust):** `ride_summary(ftp) -> RideSummary` in `ride.rs` from the 1 Hz `points`: NP, IF, TSS, max cadence, `time_in_zone_s[7]`, best 5 s/1 m/5 m/20 m, plus a ≤600-point downsampled power/HR series. Reuse `RideStats` for the rest. *Done:* unit tests (constant 200 W for 1 h at FTP 200 gives NP 200, IF 1.00, TSS 100).
- [ ] **PS2 P0 (UI):** summary screen on Stop/route complete with Save TCX (exists) / Done. Elevation gain = Σ positive Δelev of the GPX profile over [0, progress]. Map + ghost result (finish vs best, "new best") reuse RM2 + `GhostStore`.
- [ ] **PS3 P0 honesty:** a demo ride shows a "DEMO" tag and **must not call `saveIfBest`**. Today `_trackGhost` has no `isDemo` guard, so a demo run can become your best.

| Metric | Needs FTP | Demo data |
|---|---|---|
| Duration, distance, kJ, avg/max power, avg/max cadence, avg/max HR (demo simulates HR) | no | yes |
| NP (P1: VI = NP/avg) | no | yes |
| IF, TSS, time in zones (plus zone colours on the chart) | **yes** (current FTP; show it with the value) | yes |
| Power+HR chart | no | yes |
| Elevation gain, route map, ghost compare | no (needs a GPX) | yes, with a GPX loaded |
Formulas: **NP** = (mean((30 s rolling mean of 1 Hz power)^4))^¼ (blank if <30 s). **IF** = NP / FTP. **TSS** = (s × NP × IF) / (FTP × 3600) × 100 = hours × IF² × 100.

## Route identity
- [ ] **RI1 P0:** today's `routeKey()` (`lib/src/workout/route_ghost.dart:10`, called in `ride_dashboard.dart:283 _loadBestForGpx`) hashes only distance + elev×10 per raw sample. **Collision:** two flat (constant-`<ele>`) routes with the same length and point count share a key, and therefore a ghost. A reversed flat route collides too. **Also brittle the other way:** re-exporting the same route at a different point density changes the key, even though the doc comment says otherwise. (No-ele GPX is currently rejected by `parse_gpx`.)
- [ ] **RI2 P0:** compute the v2 key in Rust inside `parse_gpx` (it has lat/lon) and expose `route_key: String` on `GpxProfileInfo`. Add `sha2` to `rust/Cargo.toml`. Resample to 128 points by distance; lat/lon at 1e-4° (~11 m, survives re-export jitter; 1e-5 is stricter); ele rounded to 1 m (a different profile means a different sim effort, so a different ghost is correct); total rounded to 10 m. Reversed direction: different start → different key (intended). No ele: a sentinel distinct from 0 m.
- [ ] **RI3 P0 migration:** `GhostStore.load(v2)` → if missing, try `legacyRouteKey(p)` (keep the old function, renamed). Migrate (write v2 with `legacyKey`, keep the old file) only when `distanceM` is within 1 % **and** `routeName` matches, which guards against the flat collisions. `saveIfBest` writes v2 only. *Done:* tests: same file → same key; reversed → different; two flat 10 km routes in different places → different; legacy best still found.
```rust
use sha2::{Digest, Sha256};
/// pts: (lat, lon, ele, cum_m), cum_m strictly increasing (parse_gpx already skips <5 cm).
pub fn route_key_v2(pts: &[(f64, f64, Option<f64>, f64)]) -> String {
    const N: usize = 128;
    let total = pts.last().unwrap().3;
    let mut h = Sha256::new();
    h.update(b"tacx-route-v2");
    h.update(((total / 10.0).round() as i64).to_le_bytes());
    let mut j = 0;
    for i in 0..N {
        let d = total * i as f64 / (N - 1) as f64;
        while j + 2 < pts.len() && pts[j + 1].3 < d { j += 1; }
        let (a, b) = (&pts[j], &pts[j + 1]);
        let t = ((d - a.3) / (b.3 - a.3).max(1e-9)).clamp(0.0, 1.0);
        let l = |x: f64, y: f64| x + (y - x) * t;
        h.update(((l(a.0, b.0) * 1e4).round() as i32).to_le_bytes());
        h.update(((l(a.1, b.1) * 1e4).round() as i32).to_le_bytes());
        let e = match (a.2, b.2) { (Some(x), Some(y)) => l(x, y).round() as i32, _ => i32::MIN };
        h.update(e.to_le_bytes());
    }
    format!("v2-{}", &format!("{:x}", h.finalize())[..16])
}
```

## Acceptance (Garuda first, then Windows)
- [ ] **AC1 P0:** Demo + a GPX loaded: map draws, the dot moves smoothly along the line, the ghost dot shows on a 2nd run, CPU stays flat (dot-only repaints), 60 fps on Wayland and X11.
- [ ] **AC2 P0:** finish → summary shows every metric in the table; NP/IF/TSS match the unit-test fixture; DEMO tag shown and no ghost saved.
- [ ] **AC3 P0:** an existing v1 ghost is still found after upgrade; flat-route collision test passes; `flutter analyze` clean, CI green, ROADMAP step 3 ticked with SHA.
- [ ] **AC4 P1:** works fully offline (no network calls added); tar.gz/AppImage size within ±1 MB.

## Top 5 for Tacx Build (in order)
1. RM1 + RI2: lat/lon + `route_key` (SHA-256 v2) in `gpx.rs`/`types.rs`, one FRB regen.
2. RI3 + PS3: legacy-key fallback/migration in `GhostStore`; block demo rides from `saveIfBest`.
3. DT1 + DT2: `AppTokens` ThemeExtension + `kTabular` on all live numbers.
4. RM2: offline `RouteMap` (cached path, dot-only repaint via ValueNotifier) next to the elevation chart.
5. PS1 + PS2: Rust `ride_summary(ftp)` (NP/IF/TSS/zones/bests) + summary screen with chart, map, ghost result.
