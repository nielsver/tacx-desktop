import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

/// Elevation profile sparkline with optional progress marker (GPX / sim route).
class ElevProfileChart extends StatelessWidget {
  const ElevProfileChart({
    super.key,
    required this.profile,
    this.progressM,
    this.ghostM,
    this.height = 72,
  });

  final GpxProfileInfo profile;
  final double? progressM;

  /// Where the best attempt was at the same elapsed time (ghost marker).
  final double? ghostM;
  final double height;

  @override
  Widget build(BuildContext context) {
    final samples = profile.samples;
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
              Text(
                profile.name,
                style: const TextStyle(
                  color: RideColors.textSecondary,
                  fontSize: RideType.caption,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${(profile.distanceM / 1000).toStringAsFixed(1)} km · '
                '+${profile.elevGainM.toStringAsFixed(0)} m',
                style: const TextStyle(
                  color: RideColors.textMuted,
                  fontSize: RideType.caption,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: samples.length < 2
                ? const Center(
                    child: Text(
                      'No elevation samples',
                      style: TextStyle(
                        color: RideColors.textMuted,
                        fontSize: RideType.caption,
                      ),
                    ),
                  )
                : CustomPaint(
                    painter: ElevPainter(
                      samples,
                      progressM: progressM,
                      ghostM: ghostM,
                    ),
                    size: Size.infinite,
                  ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
class ElevPainter extends CustomPainter {
  ElevPainter(this.samples, {this.progressM, this.ghostM});

  final List<ElevSample> samples;
  final double? progressM;
  final double? ghostM;

  /// Ghost marker colour (calm violet, distinct from the warn progress line).
  static const ghostColor = Color(0xFFB39DDB);

  /// Y of the profile line at distance [d] (for markers).
  double _yAt(double d, Size size, double minE, double spanE) {
    var i = 0;
    while (i < samples.length - 2 && samples[i + 1].distanceM < d) {
      i++;
    }
    final a = samples[i], b = samples[i + 1];
    final span = b.distanceM - a.distanceM;
    final f = span <= 0 ? 0.0 : ((d - a.distanceM) / span).clamp(0.0, 1.0);
    final e = a.elevM + (b.elevM - a.elevM) * f;
    return size.height * (1 - ((e - minE) / spanE));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || size.width <= 0 || size.height <= 0) return;
    final minE = samples.map((s) => s.elevM).reduce(math.min);
    final maxE = samples.map((s) => s.elevM).reduce(math.max);
    final spanE = (maxE - minE).abs() < 1 ? 1.0 : (maxE - minE);
    final maxD = samples.last.distanceM.max(1);

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = (samples[i].distanceM / maxD) * size.width;
      final y = size.height * (1 - ((samples[i].elevM - minE) / spanE));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
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

    final ghost = ghostM;
    if (ghost != null && ghost.isFinite && ghost >= 0) {
      final gd = ghost.clamp(0.0, maxD);
      final x = (gd / maxD) * size.width;
      final y = _yAt(gd, size, minE, spanE);
      final paint = Paint()
        ..color = ghostColor
        ..strokeWidth = 1.5;
      for (var yy = 0.0; yy < size.height; yy += 6) {
        canvas.drawLine(
          Offset(x, yy),
          Offset(x, math.min(yy + 3, size.height)),
          paint,
        );
      }
      canvas.drawCircle(Offset(x, y), 5, Paint()..color = RideColors.bg);
      canvas.drawCircle(
        Offset(x, y),
        5,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    final prog = progressM;
    if (prog != null && prog >= 0) {
      final x = (prog.clamp(0.0, maxD) / maxD) * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = RideColors.warn
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(ElevPainter old) =>
      old.samples.length != samples.length ||
      old.progressM != progressM ||
      old.ghostM != ghostM ||
      !identical(old.samples, samples);
}

extension on double {
  double max(double other) => this > other ? this : other;
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
              color: ElevPainter.ghostColor,
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
