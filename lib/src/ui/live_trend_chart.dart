import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// One 1 Hz sample of the live ride (power, cadence, optional heart rate).
@immutable
class TrendSample {
  const TrendSample({
    required this.powerW,
    required this.cadenceRpm,
    this.heartRateBpm,
  });

  final double powerW;
  final double cadenceRpm;
  final int? heartRateBpm;
}

/// Rolling window of live samples for the trend graph.
///
/// The dashboard polls the trainer every 250 ms; [offer] keeps at most one
/// sample per [interval] so the graph is a steady 1 Hz history of the last
/// [capacity] seconds (10 min by default) and never grows unbounded.
class TrendBuffer extends ChangeNotifier {
  TrendBuffer({
    this.capacity = 600,
    this.interval = const Duration(seconds: 1),
  });

  final int capacity;
  final Duration interval;
  final List<TrendSample> _samples = [];
  DateTime? _last;

  List<TrendSample> get samples => List.unmodifiable(_samples);
  int get length => _samples.length;
  bool get isEmpty => _samples.isEmpty;

  /// Adds [m] when at least [interval] passed since the previous sample.
  /// Returns true when a sample was recorded.
  bool offer(TrainerMetrics m, DateTime now) {
    final last = _last;
    if (last != null && now.difference(last) < interval) return false;
    _last = now;
    _samples.add(
      TrendSample(
        powerW: m.powerW.isFinite ? math.max(0, m.powerW) : 0,
        cadenceRpm: m.cadenceRpm.isFinite ? math.max(0, m.cadenceRpm) : 0,
        heartRateBpm: (m.heartRateBpm ?? 0) > 0 ? m.heartRateBpm : null,
      ),
    );
    if (_samples.length > capacity) {
      _samples.removeRange(0, _samples.length - capacity);
    }
    notifyListeners();
    return true;
  }

  void clear() {
    if (_samples.isEmpty && _last == null) return;
    _samples.clear();
    _last = null;
    notifyListeners();
  }
}

/// Compact live graph of power (filled), cadence and heart rate over the
/// last minutes. Each series is scaled to its own range so all three stay
/// readable; the legend shows the latest value in the series colour.
class LiveTrendChart extends StatelessWidget {
  const LiveTrendChart({super.key, required this.buffer, this.height = 88});

  final TrendBuffer buffer;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: buffer,
      builder: (context, _) {
        final s = buffer.samples;
        final last = s.isEmpty ? null : s.last;
        final hasHr = s.any((e) => e.heartRateBpm != null);
        final minutes = (s.length / 60).ceil();
        return Container(
          key: const ValueKey('live-trend-chart'),
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
                  const Text(
                    'Live graph',
                    style: TextStyle(
                      color: RideColors.textSecondary,
                      fontSize: RideType.caption,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _Legend(
                    color: RideColors.power,
                    label: last == null
                        ? 'Power'
                        : '${last.powerW.toStringAsFixed(0)} W',
                  ),
                  const SizedBox(width: 10),
                  _Legend(
                    color: RideColors.cadence,
                    label: last == null
                        ? 'Cadence'
                        : '${last.cadenceRpm.toStringAsFixed(0)} rpm',
                  ),
                  if (hasHr) ...[
                    const SizedBox(width: 10),
                    _Legend(
                      color: RideColors.heart,
                      label: last?.heartRateBpm == null
                          ? 'HR —'
                          : '${last!.heartRateBpm} bpm',
                    ),
                  ],
                  const Spacer(),
                  Text(
                    s.isEmpty ? '' : 'last ${minutes.clamp(1, 10)} min',
                    style: const TextStyle(
                      color: RideColors.textMuted,
                      fontSize: RideType.caption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: s.length < 2
                    ? const Center(
                        child: Text(
                          'Graph starts once the trainer sends data',
                          style: TextStyle(
                            color: RideColors.textMuted,
                            fontSize: RideType.caption,
                          ),
                        ),
                      )
                    : CustomPaint(
                        painter: TrendPainter(s, capacity: buffer.capacity),
                        size: Size.infinite,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: RideType.caption,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

@visibleForTesting
class TrendPainter extends CustomPainter {
  TrendPainter(this.samples, {required this.capacity});

  final List<TrendSample> samples;
  final int capacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || size.width <= 0 || size.height <= 0) return;
    // Faint guide lines at 1/3 and 2/3 height.
    final grid = Paint()
      ..color = RideColors.border.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final f in const [1 / 3, 2 / 3]) {
      canvas.drawLine(
        Offset(0, size.height * f),
        Offset(size.width, size.height * f),
        grid,
      );
    }
    // Fill from the right edge so the newest sample is always at the right.
    final span = math.max(capacity - 1, samples.length - 1);
    final dx = size.width / span;
    final x0 = size.width - (samples.length - 1) * dx;

    double maxOf(Iterable<double> v, double floor) =>
        v.fold<double>(floor, math.max);

    final pMax = maxOf(samples.map((e) => e.powerW), 100) * 1.1;
    final cMax = maxOf(samples.map((e) => e.cadenceRpm), 60) * 1.1;

    Path line(double Function(TrendSample) y01) {
      final p = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = x0 + i * dx;
        final y = size.height * (1 - y01(samples[i]).clamp(0.0, 1.0));
        i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      return p;
    }

    final power = line((e) => e.powerW / pMax);
    final fill = Path.from(power)
      ..lineTo(size.width, size.height)
      ..lineTo(x0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = RideColors.power.withValues(alpha: 0.18),
    );
    canvas.drawPath(
      power,
      Paint()
        ..color = RideColors.power
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      line((e) => e.cadenceRpm / cMax),
      Paint()
        ..color = RideColors.cadence
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final hr = samples
        .where((e) => e.heartRateBpm != null)
        .map((e) => e.heartRateBpm!.toDouble());
    if (hr.isNotEmpty) {
      final hMin = math.max(40.0, hr.reduce(math.min) - 10);
      final hMax = math.max(hMin + 40, hr.reduce(math.max) + 10);
      final p = Path();
      var pen = false;
      for (var i = 0; i < samples.length; i++) {
        final b = samples[i].heartRateBpm;
        if (b == null) {
          pen = false;
          continue;
        }
        final x = x0 + i * dx;
        final y =
            size.height * (1 - ((b - hMin) / (hMax - hMin)).clamp(0.0, 1.0));
        pen ? p.lineTo(x, y) : p.moveTo(x, y);
        pen = true;
      }
      canvas.drawPath(
        p,
        Paint()
          ..color = RideColors.heart
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(TrendPainter old) =>
      old.samples.length != samples.length ||
      !identical(old.samples, samples) ||
      old.capacity != capacity;
}
