import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Ghost marker colour (same as the elevation profile's ghost).
const Color kGhostColor = Color(0xFFB39DDB);

/// (min elevation, span ≥ 1 m) for scaling an elevation profile.
(double, double) profileElevRange(List<ElevSample> samples) {
  if (samples.isEmpty) return (0.0, 1.0);
  var lo = double.infinity, hi = double.negativeInfinity;
  for (final s in samples) {
    lo = math.min(lo, s.elevM);
    hi = math.max(hi, s.elevM);
  }
  return (lo, (hi - lo).abs() < 1 ? 1.0 : hi - lo);
}

/// Elevation gain over [0, upToM] metres with the same 2 m hysteresis as
/// Rust `gpx::elevation_gain` (so a full ride matches the GPX header).
double elevGainUpTo(
  List<ElevSample> samples,
  double upToM, {
  double threshold = 2,
}) {
  if (samples.length < 2 || !(upToM > 0)) return 0;
  final es = <double>[];
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    if (s.distanceM <= upToM) {
      es.add(s.elevM);
      continue;
    }
    final a = samples[i - 1];
    final span = s.distanceM - a.distanceM;
    final t = span <= 0 ? 0.0 : (upToM - a.distanceM) / span;
    es.add(a.elevM + (s.elevM - a.elevM) * t);
    break;
  }
  var gain = 0.0, low = es.first, high = es.first;
  var climbing = false;
  for (final e in es.skip(1)) {
    if (climbing) {
      if (e > high) {
        gain += e - high;
        high = e;
      } else if (high - e >= threshold) {
        climbing = false;
        low = e;
      }
    } else if (e < low) {
      low = e;
    } else if (e - low >= threshold) {
      gain += e - low;
      high = e;
      climbing = true;
    }
  }
  return gain;
}

/// Projected route geometry. Build it **once per GPX load**; screen points
/// and the path are cached per size.
///
/// Offline by design: no tiles, no network, no flutter_map (OSM tile policy
/// forbids prefetching, and the offline tile plugin is GPL-3.0).
class RouteGeo {
  RouteGeo(this.samples)
    : _cosLat = samples.isEmpty
          ? 1
          : math.cos(
              samples.map((e) => e.lat).reduce((a, b) => a + b) /
                  samples.length *
                  math.pi /
                  180,
            );

  final List<ElevSample> samples;
  final double _cosLat;

  Size? _size;
  List<Offset> _xy = const [];
  Path _path = Path();

  bool get isDrawable => samples.length >= 2;
  double get distanceM => samples.isEmpty ? 0 : samples.last.distanceM;

  List<Offset> get points => _xy;
  Path get path => _path;

  /// Equirectangular projection around the centroid, fitted (90 %) into
  /// [s], north up. No-op when the size didn't change.
  void fit(Size s) {
    if (s == _size || !isDrawable) return;
    _size = s;
    final raw = [for (final e in samples) Offset(e.lon * _cosLat, -e.lat)];
    var r = Rect.fromPoints(raw.first, raw.first);
    for (final o in raw) {
      r = r.expandToInclude(Rect.fromPoints(o, o));
    }
    final sc =
        0.9 *
        math.min(
          s.width / math.max(r.width, 1e-9),
          s.height / math.max(r.height, 1e-9),
        );
    final off = s.center(Offset.zero) - r.center * sc;
    _xy = [for (final o in raw) o * sc + off];
    _path = Path()..addPolygon(_xy, false);
  }

  /// Segment index and fraction at [m] metres along the route (binary
  /// search). One lookup shared by the map and the elevation chart.
  /// Requires [isDrawable].
  ({int i, double t}) locate(double m) {
    final s = samples;
    if (!(m > 0)) return (i: 0, t: 0.0);
    if (m >= s.last.distanceM) return (i: s.length - 2, t: 1.0);
    var lo = 0, hi = s.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (s[mid].distanceM <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = s[lo].distanceM, span = s[hi].distanceM - a;
    return (i: lo, t: span <= 0 ? 0.0 : (m - a) / span);
  }

  /// Interpolated position, elevation and grade at [m] metres.
  ({double lat, double lon, double elev, double grade}) distanceToPoint(
    double m,
  ) {
    final (:i, :t) = locate(m);
    final a = samples[i], b = samples[i + 1];
    double l(double x, double y) => x + (y - x) * t;
    return (
      lat: l(a.lat, b.lat),
      lon: l(a.lon, b.lon),
      elev: l(a.elevM, b.elevM),
      grade: l(a.gradePct, b.gradePct), // centred-window grades (gpx.rs)
    );
  }

  (double, double)? _elevRange;

  /// (min elevation, span ≥ 1 m), computed once.
  (double, double) get elevRange => _elevRange ??= profileElevRange(samples);

  /// Screen position at [d] metres along the route (after [fit]).
  Offset at(double d) {
    if (_xy.length < 2) return _xy.isEmpty ? Offset.zero : _xy.first;
    if (!d.isFinite) return _xy.first;
    final (:i, :t) = locate(d);
    return Offset.lerp(_xy[i], _xy[i + 1], t)!;
  }

  /// Metres along the route of the projected point nearest [p], if it is
  /// within [maxPx] (after [fit]). O(n); fine up to ~10k samples.
  double? nearestM(Offset p, {double maxPx = 12}) {
    var k = -1;
    var bd = maxPx * maxPx;
    for (var j = 0; j < _xy.length; j++) {
      final d = (_xy[j] - p).distanceSquared;
      if (d < bd) {
        bd = d;
        k = j;
      }
    }
    return k < 0 ? null : samples[k].distanceM;
  }
}

/// Offline route map: static route line + start/finish markers (one
/// painter, repaints only on resize / new route) and a rider / ghost dot
/// layer that repaints alone when [progressM] / [ghostM] change.
class RouteMap extends StatelessWidget {
  const RouteMap({
    super.key,
    required this.geo,
    required this.progressM,
    required this.ghostM,
    this.hoverM,
    this.onHover,
  });

  final RouteGeo geo;
  final ValueListenable<double?> progressM;
  final ValueListenable<double?> ghostM;

  /// Preview position from chart / map hover (hollow ring, own layer).
  final ValueListenable<double?>? hoverM;

  /// Map hover → metres along the route within 12 px of the line, else null.
  final ValueChanged<double?>? onHover;

  @override
  Widget build(BuildContext context) {
    if (!geo.isDrawable) return const SizedBox.shrink();
    final hover = onHover;
    Widget map = Stack(
      fit: StackFit.expand,
      alignment: Alignment.topLeft,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            key: const ValueKey('route-map-line'),
            painter: RouteLinePainter(geo),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            key: const ValueKey('route-map-dots'),
            painter: RouteDotPainter(geo, progressM, ghostM),
          ),
        ),
        if (hoverM != null)
          RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('route-map-hover'),
              painter: RouteHoverPainter(geo, hoverM!),
            ),
          ),
      ],
    );
    if (hover != null) {
      map = MouseRegion(
        onHover: (e) => hover(geo.nearestM(e.localPosition)),
        onExit: (_) => hover(null),
        child: map,
      );
    }
    return Semantics(label: 'Route map', child: map);
  }
}

/// Hollow preview ring at the hovered distance; its own layer so hovering
/// never repaints the rider dot or the route line.
class RouteHoverPainter extends CustomPainter {
  RouteHoverPainter(this.geo, this.hoverM) : super(repaint: hoverM);

  final RouteGeo geo;
  final ValueListenable<double?> hoverM;

  @visibleForTesting
  static int debugPaints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    debugPaints++;
    geo.fit(size);
    final h = hoverM.value;
    if (h == null || !h.isFinite) return;
    final o = geo.at(h);
    canvas.drawCircle(
      o,
      8,
      Paint()..color = RideColors.bg.withValues(alpha: 0.4),
    );
    canvas.drawCircle(
      o,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = RideColors.textPrimary,
    );
  }

  @override
  bool shouldRepaint(RouteHoverPainter old) =>
      !identical(old.geo, geo) || old.hoverM != hoverM;
}

class RouteLinePainter extends CustomPainter {
  RouteLinePainter(this.geo);
  final RouteGeo geo;

  @visibleForTesting
  static int debugPaints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    debugPaints++;
    geo.fit(size);
    if (geo.points.length < 2) return;
    canvas.drawPath(
      geo.path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = RideColors.border,
    );
    canvas.drawPath(
      geo.path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = RideColors.accent.withValues(alpha: 0.85),
    );
    // Start (hollow) and finish (chequered-ish square).
    canvas.drawCircle(
      geo.points.first,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = RideColors.ok,
    );
    canvas.drawRect(
      Rect.fromCenter(center: geo.points.last, width: 8, height: 8),
      Paint()..color = RideColors.textPrimary,
    );
  }

  @override
  bool shouldRepaint(RouteLinePainter old) => !identical(old.geo, geo);
}

class RouteDotPainter extends CustomPainter {
  RouteDotPainter(this.geo, this.progressM, this.ghostM)
    : super(repaint: Listenable.merge([progressM, ghostM]));

  final RouteGeo geo;
  final ValueListenable<double?> progressM;
  final ValueListenable<double?> ghostM;

  @visibleForTesting
  static int debugPaints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    debugPaints++;
    geo.fit(size);
    final g = ghostM.value;
    if (g != null) {
      final o = geo.at(g);
      canvas.drawCircle(
        o,
        6,
        Paint()..color = kGhostColor.withValues(alpha: 0.35),
      );
      canvas.drawCircle(
        o,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = kGhostColor,
      );
    }
    final p = progressM.value;
    if (p != null) {
      final o = geo.at(p);
      canvas.drawCircle(o, 7, Paint()..color = RideColors.bg);
      canvas.drawCircle(o, 5.5, Paint()..color = RideColors.power);
    }
  }

  @override
  bool shouldRepaint(RouteDotPainter old) =>
      !identical(old.geo, geo) ||
      old.progressM != progressM ||
      old.ghostM != ghostM;
}
