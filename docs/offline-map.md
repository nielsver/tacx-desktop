# tacx-desktop offline route map: addendum to RM1–RM3 (pro-polish checklist)
*2026-10-08 (Brussels). Research only, no code pushed. Base: `origin/main` @ `06561a9` (RouteMap/RouteGeo already shipped). Versions from the pub.dev API today. Sizes were measured with `flutter build linux --release` on Flutter 3.35.5 (same as CI) in a scratch app: a bare app's bundle is 48.7 MB. pub.dev lists every package below for Linux and Windows. I built on Linux only.*

| Option | Licence | Native deps | Added size (measured) | Offline | Effort / verdict |
|---|---|---|---|---|---|
| **(a) CustomPainter** (shipped) | own (MIT) | none | 0 | yes | done. **Keep** |
| flutter_map 8.3.2, **no TileLayer** (Polyline + Marker only) | BSD-3; latlong2 0.10.1 Apache-2.0; proj4dart 3.0.0 MIT | none (pure Dart, ~29 extra lock entries: http, path_provider, uuid, intl, earcut…) | +0.36 MB libapp.so | yes (no TileLayer = no network) | S–M to swap. Adds pan/zoom/fling, `CameraFit.coordinates`, EPSG:3857 CRS, polyline hit-testing. You lose the dot-only repaint control. Not worth it in a fixed side panel |
| + **MBTiles** `flutter_map_mbtiles` 1.0.4 (MIT) → `mbtiles` (BSD-3) | SQLite bundled by `sqlite3_flutter_libs` 0.5.42 (sqlite statically linked, no system libsqlite3 needed) | +0.56 MB Dart, +1.84 MB `libsqlite3_flutter_libs_plugin.so` = **+2.4 MB**, plus the basemap | yes | M–L, **stale**: last release Feb 2025. It pins `mbtiles` 0.4.2 / `sqlite3` 2.9.4 and `sqlite3_flutter_libs` (now `0.6.0+eol`), and downgrades latlong2 to 0.9.1. Raster only |
| + **PMTiles raster** `flutter_map_pmtiles` 1.0.5 (MIT) → `pmtiles` (BSD-2) | none (pure Dart: archive, protobuf) | **+0.89 MB**, plus the basemap | yes (local file) | M, but no free *raster* .pmtiles is published (Protomaps builds are vector), so you'd have to render it yourself. Also stale: pins pmtiles 1.3.0 (latest 2.2.0) and downgrades latlong2→0.9.1, proj4dart→2.1.0 |
| + **PMTiles vector** `vector_map_tiles` (BSD-3) + `vector_map_tiles_pmtiles` 1.5.0 (MIT) | none | n/a | yes | **Blocked today.** No version set resolves with flutter_map 8.3.2 on Flutter 3.35.5: stable vmt 8.0.0 needs flutter_map ^7; 9.0.0-beta.13 conflicts with vmt_pmtiles (renderer ^5 vs ^6); 10.0.0-beta needs Flutter ≥3.37 |
| Static pre-rendered image | your own; ODbL if made from OSM | none, but needs an offline renderer | ~0.1–1 MB per route | yes | L: one render per GPX, plus the projection must match exactly. **Not worth it** |

**Basemap sizes.** Protomaps v4 vector, build `20261007`, `pmtiles extract --dry-run` (measured):
- Belgium z0–14: **556 MB**; Belgium z0–12: 140 MB
- Benelux z0–14: **1.2 GB**
- World z0–6: 45 MB

Raster is an estimate (tile counts are exact, size per tile assumed 10–25 KB): Belgium z0–14 = 34,779 tiles ≈ 0.35–0.9 GB; Benelux z0–14 = 86,166 tiles ≈ 0.9–2.2 GB. Bulk-fetching tile.openstreetmap.org is banned. **Never put a basemap in the tar.gz, AppImage, .deb or Inno installer.** Use an opt-in download or a user-picked file in `$XDG_DATA_HOME/tacx_desktop/maps/` (`%APPDATA%` on Windows), and host the extract yourself, e.g. as a GitHub release asset (Protomaps discourages hotlinking its builds).

**Licences.** OSM tiles are an ODbL *Produced Work*. They need a visible "© OpenStreetMap contributors" in the map corner (`SimpleAttributionWidget`) and in About/licences. Protomaps: code BSD-3, style CC0 (crediting Protomaps is requested, not required), and a modified fork must not be called "Protomaps". OpenMapTiles schema/styles are CC-BY 4.0, which adds "© OpenMapTiles". Everything above is MIT-compatible (unlike FMTC's GPL).

## Checklist
- [ ] **OM1 P0: one lookup, one source of truth.** Add `locate(m)` / `distanceToPoint(m)` to `RouteGeo` (binary search + lerp; sketch below). `RouteGeo.at()` and the chart both use it. Today `ElevPainter._yAt` is an O(n) linear scan, and the chart gets plain `double?` values, so the whole profile path is rebuilt on every 4 Hz refresh.
- [ ] **OM2 P0: chart cursor layer.** Split `ElevProfileChart` into a static `ElevPainter` (inside a `RepaintBoundary`) and an `ElevCursorPainter(repaint: Listenable.merge([_mapRiderM, _mapGhostM, _hoverM]))`. The ride keeps writing `_mapRiderM` at 4 Hz. Hover/drag on the chart writes a new `_hoverM` (`null` on exit or drag end).
- [ ] **OM3 P0: preview dot.** `RouteDotPainter` adds `hoverM` to its merge and draws a hollow ring at `geo.at(hoverM)`. The chart draws a dashed cursor with a "12.4 km · 87 m · 6.2 %" label. *Done when:* hovering the chart moves only the ring (DevTools repaint rainbow), and the rider dot is untouched.
- [ ] **OM4 P1: reverse lookup.** A `MouseRegion` on the map sets `_hoverM = geo.nearestM(pos)` when the pointer is within 12 px of the line, else `null`. O(n) over the projected points is fine up to about 10k samples.
- [ ] **OM5 P1, lighter extras on (a) that are worth doing:** a scale bar (`mPerPx = 111320 / sc`; store `sc` in `fit()`), a tiny "N" (the map is always north-up), and km ticks via `at(k*1000)`. Optional zoom with `InteractiveViewer` (Flutter SDK, no deps): use stroke `3/scale`. Skip hillshade and static images.
- [ ] **OM6 P1 later, only if Niels wants streets:** a "Street basemap (download ~140–560 MB)" setting. Prefer flutter_map + vector PMTiles once `vector_map_tiles` is stable on flutter_map 8. Until then use raster PMTiles (pure Dart, +0.9 MB), not MBTiles (EOL sqlite plugin). (a) stays the default and the fallback.

```dart
// ride_dashboard state (metres along route). _mapRiderM/_mapGhostM exist; add:
final _hoverM = ValueNotifier<double?>(null); // chart/map hover; null = none (dispose it)

extension RouteLocate on RouteGeo { // one binary search + lerp for map AND chart
  ({int i, double t}) locate(double m) { // needs isDrawable (≥2 samples)
    final s = samples;
    if (!(m > 0)) return (i: 0, t: 0.0);
    if (m >= s.last.distanceM) return (i: s.length - 2, t: 1.0);
    var lo = 0, hi = s.length - 1;
    while (hi - lo > 1) { final mid = (lo + hi) >> 1; s[mid].distanceM <= m ? lo = mid : hi = mid; }
    final a = s[lo].distanceM, span = s[hi].distanceM - a;
    return (i: lo, t: span <= 0 ? 0.0 : (m - a) / span);
  }
  ({double lat, double lon, double elev, double grade}) distanceToPoint(double m) {
    final (:i, :t) = locate(m); final a = samples[i], b = samples[i + 1];
    double l(double x, double y) => x + (y - x) * t;
    return (lat: l(a.lat, b.lat), lon: l(a.lon, b.lon), elev: l(a.elevM, b.elevM), grade: a.gradePct);
  }
  double? nearestM(Offset p, {double maxPx = 12}) { // P1: map hover -> metres
    var k = -1; var bd = maxPx * maxPx;
    for (var j = 0; j < points.length; j++) { final d = (points[j] - p).distanceSquared; if (d < bd) { bd = d; k = j; } }
    return k < 0 ? null : samples[k].distanceM;
  }
}
// chart: static profile + cursor layer; hover/drag writes _hoverM
LayoutBuilder(builder: (_, c) { double toM(Offset p) => (p.dx / c.maxWidth).clamp(0.0, 1.0) * geo.distanceM;
  return MouseRegion(onHover: (e) => _hoverM.value = toM(e.localPosition), onExit: (_) => _hoverM.value = null,
    child: GestureDetector(onHorizontalDragUpdate: (e) => _hoverM.value = toM(e.localPosition),
      onHorizontalDragEnd: (_) => _hoverM.value = null,
      child: Stack(fit: StackFit.expand, children: [
        RepaintBoundary(child: CustomPaint(painter: ElevPainter(geo.samples))),
        CustomPaint(painter: ElevCursorPainter(geo, _mapRiderM, _mapGhostM, _hoverM)), // repaint-only
      ])));
});
// ElevCursorPainter(...) : super(repaint: Listenable.merge([rider, ghost, hover])); paint: x = m/geo.distanceM*w,
//   y from distanceToPoint(m).elev. RouteDotPainter: same merge + hover → hollow ring at geo.at(hoverM).
```
