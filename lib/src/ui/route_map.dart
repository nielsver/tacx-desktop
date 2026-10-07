import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Ghost marker colour (same as the elevation profile's ghost).
const Color kGhostColor = Color(0xFFB39DDB);

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

  /// Screen position at [d] metres along the route (after [fit]).
  Offset at(double d) {
    if (_xy.isEmpty) return Offset.zero;
    if (!d.isFinite || d <= 0) return _xy.first;
    if (d >= samples.last.distanceM) return _xy.last;
    var lo = 0, hi = samples.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) >> 1;
      if (samples[m].distanceM <= d) {
        lo = m;
      } else {
        hi = m;
      }
    }
    final a = samples[lo].distanceM;
    final span = samples[hi].distanceM - a;
    return Offset.lerp(_xy[lo], _xy[hi], span <= 0 ? 0 : (d - a) / span)!;
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
  });

  final RouteGeo geo;
  final ValueListenable<double?> progressM;
  final ValueListenable<double?> ghostM;

  @override
  Widget build(BuildContext context) {
    if (!geo.isDrawable) return const SizedBox.shrink();
    return Semantics(
      label: 'Route map',
      child: Stack(
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
        ],
      ),
    );
  }
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
