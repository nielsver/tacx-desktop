import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Elevation profile sparkline with optional progress marker (GPX / sim route).
class ElevProfileChart extends StatelessWidget {
  const ElevProfileChart({
    super.key,
    required this.profile,
    this.progressM,
    this.height = 72,
  });

  final GpxProfileInfo profile;
  final double? progressM;
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
                    painter: ElevPainter(samples, progressM: progressM),
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
  ElevPainter(this.samples, {this.progressM});

  final List<ElevSample> samples;
  final double? progressM;

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
      !identical(old.samples, samples);
}

extension on double {
  double max(double other) => this > other ? this : other;
}
