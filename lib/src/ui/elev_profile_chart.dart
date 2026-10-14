import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

/// Elevation profile (GPX / sim route) in two layers: a static profile
/// that repaints only for a new route or size, and a cursor layer (rider,
/// ghost, hover) driven by [ValueListenable]s, so the 4 Hz ride refresh
/// never redraws the profile path.
///
/// Hover or horizontal drag reports metres along the route via [onHover]
/// (`null` on exit / drag end); the dashboard feeds that into [hoverM],
/// which also drives the preview ring on the route map.
class ElevProfileChart extends StatelessWidget {
  const ElevProfileChart({
    super.key,
    required this.profile,
    this.geo,
    this.riderM,
    this.ghostM,
    this.hoverM,
    this.onHover,
    this.height = 72,
  });

  final GpxProfileInfo profile;

  /// Shared route geometry (built once per GPX); one is made if omitted.
  final RouteGeo? geo;
  final ValueListenable<double?>? riderM;

  /// Where the best attempt was at the same elapsed time (ghost marker).
  final ValueListenable<double?>? ghostM;
  final ValueListenable<double?>? hoverM;
  final ValueChanged<double?>? onHover;
  final double height;

  @override
  Widget build(BuildContext context) {
    final samples = profile.samples;
    final g = geo ?? RouteGeo(samples);
    return Container(
      key: const ValueKey('elev-profile-chart'),
      height: height,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: RideColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RideColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: RideColors.textSecondary,
                    fontSize: RideType.caption,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(profile.distanceM / 1000).toStringAsFixed(1)} km · '
                '+${profile.elevGainM.toStringAsFixed(0)} m',
                style: const TextStyle(
                  color: RideColors.textMuted,
                  fontSize: RideType.caption,
                  fontFeatures: kTabularFeatures,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: !g.isDrawable
                ? const Center(
                    child: Text(
                      'No elevation samples',
                      style: TextStyle(
                        color: RideColors.textMuted,
                        fontSize: RideType.caption,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, c) {
                      double toM(Offset p) =>
                          (p.dx / math.max(c.maxWidth, 1)).clamp(0.0, 1.0) *
                          g.distanceM;
                      final hover = onHover;
                      Widget body = Stack(
                        fit: StackFit.expand,
                        alignment: Alignment.topLeft,
                        children: [
                          RepaintBoundary(
                            child: CustomPaint(
                              key: const ValueKey('elev-static'),
                              painter: ElevPainter(samples),
                            ),
                          ),
                          RepaintBoundary(
                            child: CustomPaint(
                              key: const ValueKey('elev-cursor'),
                              painter: ElevCursorPainter(
                                g,
                                rider: riderM,
                                ghost: ghostM,
                                hover: hoverM,
                              ),
                            ),
                          ),
                        ],
                      );
                      if (hover != null) {
                        body = MouseRegion(
                          onHover: (e) => hover(toM(e.localPosition)),
                          onExit: (_) => hover(null),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (e) =>
                                hover(toM(e.localPosition)),
                            onHorizontalDragEnd: (_) => hover(null),
                            onHorizontalDragCancel: () => hover(null),
                            child: body,
                          ),
                        );
                      }
                      return body;
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Static profile line + fill. Repaints only for a new sample list.
@visibleForTesting
class ElevPainter extends CustomPainter {
  ElevPainter(this.samples);

  final List<ElevSample> samples;

  /// Ghost marker colour (calm violet, distinct from the warn progress line).
  static const ghostColor = kGhostColor;

  @visibleForTesting
  static int debugPaints = 0;

  /// Points in the last built path (for tests: ~2 per pixel column).
  @visibleForTesting
  static int debugLastPathPoints = 0;

  /// Paths reused from the per-route cache.
  @visibleForTesting
  static int debugCacheHits = 0;

  static final Expando<_ElevPathCache> _cache = Expando('elev-path');

  /// Profile line decimated to min/max per pixel column (QA C3.4: a 125k
  /// sample route cost ~10 ms per paint). Cached per route + size.
  static Path buildPath(List<ElevSample> samples, Size size) {
    final (minE, spanE) = profileElevRange(samples);
    final maxD = math.max(samples.last.distanceM, 1.0);
    double y(double e) => size.height * (1 - ((e - minE) / spanE));
    final cols = math.max(1, size.width.ceil());
    final path = Path();
    var n = 0;
    void add(double x, double e) {
      n == 0 ? path.moveTo(x, y(e)) : path.lineTo(x, y(e));
      n++;
    }

    if (samples.length <= cols * 2) {
      for (final s in samples) {
        add(s.distanceM / maxD * size.width, s.elevM);
      }
    } else {
      var i = 0;
      for (var c = 0; c < cols && i < samples.length; c++) {
        final edge = (c + 1) / cols * maxD;
        var lo = samples[i], hi = samples[i];
        var loI = i, hiI = i;
        while (i < samples.length &&
            (samples[i].distanceM <= edge || c == cols - 1)) {
          final s = samples[i];
          if (s.elevM < lo.elevM) {
            lo = s;
            loI = i;
          }
          if (s.elevM > hi.elevM) {
            hi = s;
            hiI = i;
          }
          i++;
        }
        final x = (c + 0.5) / cols * size.width;
        if (c == 0) add(0, samples.first.elevM);
        if (loI <= hiI) {
          add(x, lo.elevM);
          if (hiI != loI) add(x, hi.elevM);
        } else {
          add(x, hi.elevM);
          add(x, lo.elevM);
        }
      }
      add(size.width, samples.last.elevM);
    }
    debugLastPathPoints = n;
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    debugPaints++;
    if (samples.length < 2 || size.width <= 0 || size.height <= 0) return;
    final cached = _cache[samples];
    final Path path;
    if (cached != null && cached.size == size) {
      debugCacheHits++;
      path = cached.path;
    } else {
      path = buildPath(samples, size);
      _cache[samples] = _ElevPathCache(size, path);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = RideColors.accentAlt.withValues(alpha: 0.2),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = RideColors.accentAlt
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(ElevPainter old) => !identical(old.samples, samples);
}

/// "12.4 km · 87 m · 6.2 %" for the hover cursor.
String elevCursorLabel(RouteGeo geo, double m) {
  final p = geo.distanceToPoint(m);
  return '${(m / 1000).toStringAsFixed(1)} km · '
      '${p.elev.toStringAsFixed(0)} m · '
      '${p.grade.toStringAsFixed(1)} %';
}

/// Rider line, ghost marker and hover cursor over the static profile.
/// Repaints alone whenever one of its listenables changes.
class ElevCursorPainter extends CustomPainter {
  ElevCursorPainter(this.geo, {this.rider, this.ghost, this.hover})
    : super(
        repaint: Listenable.merge([
          if (rider != null) rider,
          if (ghost != null) ghost,
          if (hover != null) hover,
        ]),
      );

  final RouteGeo geo;
  final ValueListenable<double?>? rider;
  final ValueListenable<double?>? ghost;
  final ValueListenable<double?>? hover;

  @visibleForTesting
  static int debugPaints = 0;

  static bool _ok(double? m) => m != null && m.isFinite && m >= 0;

  @override
  void paint(Canvas canvas, Size size) {
    debugPaints++;
    if (!geo.isDrawable || size.width <= 0 || size.height <= 0) return;
    final (minE, spanE) = geo.elevRange;
    final maxD = math.max(geo.distanceM, 1.0);
    double xOf(double m) => (m.clamp(0.0, maxD) / maxD) * size.width;
    double yOf(double m) =>
        size.height * (1 - ((geo.distanceToPoint(m).elev - minE) / spanE));

    void dashed(double x, Paint p) {
      for (var yy = 0.0; yy < size.height; yy += 6) {
        canvas.drawLine(
          Offset(x, yy),
          Offset(x, math.min(yy + 3, size.height)),
          p,
        );
      }
    }

    final g = ghost?.value;
    if (_ok(g)) {
      final x = xOf(g!), y = yOf(g);
      final paint = Paint()
        ..color = kGhostColor
        ..strokeWidth = 1.5;
      dashed(x, paint);
      canvas.drawCircle(Offset(x, y), 5, Paint()..color = RideColors.bg);
      canvas.drawCircle(
        Offset(x, y),
        5,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    final r = rider?.value;
    if (_ok(r)) {
      final x = xOf(r!);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = RideColors.warn
          ..strokeWidth = 2,
      );
    }

    final h = hover?.value;
    if (_ok(h)) {
      final x = xOf(h!), y = yOf(h);
      dashed(
        x,
        Paint()
          ..color = RideColors.textSecondary
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        Offset(x, y),
        4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = RideColors.textPrimary,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: elevCursorLabel(geo, h),
          style: const TextStyle(
            color: RideColors.textPrimary,
            fontSize: 11,
            fontFeatures: kTabularFeatures,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (x + 6 + tp.width > size.width) ? x - 6 - tp.width : x + 6;
      final rect = Rect.fromLTWH(lx - 3, 0, tp.width + 6, tp.height + 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = RideColors.bg.withValues(alpha: 0.85),
      );
      tp.paint(canvas, Offset(lx, 1));
    }
  }

  @override
  bool shouldRepaint(ElevCursorPainter old) =>
      !identical(old.geo, geo) ||
      old.rider != rider ||
      old.ghost != ghost ||
      old.hover != hover;
}

/// "+0:12 vs best" chip: behind the best attempt is warm, ahead is green.
class GhostDeltaChip extends StatelessWidget {
  const GhostDeltaChip({super.key, required this.deltaS, this.large = false});

  /// Seconds behind (+) or ahead (−) of the best attempt.
  final double deltaS;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final r = deltaS.round();
    final color = r > 0
        ? RideColors.warn
        : (r < 0 ? RideColors.ok : RideColors.textSecondary);
    return Container(
      key: const ValueKey('ghost-delta-chip'),
      padding: EdgeInsets.symmetric(
        horizontal: large ? 12 : 10,
        vertical: large ? 6 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: kGhostColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${fmtDelta(deltaS)} vs best',
            style: TextStyle(
              color: color,
              fontSize: large ? RideType.title : RideType.label,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ElevPathCache {
  _ElevPathCache(this.size, this.path);
  final Size size;
  final Path path;
}
