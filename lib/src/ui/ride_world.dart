import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Fixed-loop ride scene. Speed and cadence are inputs; the scene integrates
/// its own distance. This is a virtual view, not the trainer's wheel speed.
class RideWorld extends StatefulWidget {
  const RideWorld({
    super.key,
    required this.speedMps,
    required this.cadenceRpm,
    this.gradePct = 0,
  });

  final double speedMps;
  final double cadenceRpm;

  /// Percent. Positive is uphill. The first FTP world passes 0.
  final double gradePct;

  @override
  State<RideWorld> createState() => _RideWorldState();
}

class _RideWorldState extends State<RideWorld>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  double _distanceM = 0;
  double _crankRad = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    if (!mounted || dt <= 0 || dt > 0.25) return;
    final speed = _finite(widget.speedMps, 0, 40);
    final cadence = _finite(widget.cadenceRpm, 0, 220);
    if (speed == 0 && cadence == 0) return;
    setState(() {
      _distanceM += speed * dt;
      _crankRad += cadence / 60.0 * dt * math.pi * 2;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speed = _finite(widget.speedMps, 0, 40);
    final kmh = (speed * 3.6).round();
    return Semantics(
      container: true,
      label: 'Virtual ride, $kmh kilometers per hour',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: RideColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: _RideWorldPainter(
                    distanceM: _distanceM,
                    crankRad: _crankRad,
                    gradePct: widget.gradePct.isFinite ? widget.gradePct : 0,
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 10,
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$kmh km/h',
                        style: const TextStyle(
                          color: RideColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Text(
                        'Virtual speed · from power',
                        style: TextStyle(
                          color: RideColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _finite(double value, double min, double max) {
  if (!value.isFinite) return min;
  return value.clamp(min, max);
}

class _RideWorldPainter extends CustomPainter {
  const _RideWorldPainter({
    required this.distanceM,
    required this.crankRad,
    required this.gradePct,
  });

  final double distanceM;
  final double crankRad;
  final double gradePct;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || size.height < 2) return;
    _paintSky(canvas, size);
    _paintRidges(canvas, size);
    _paintRoad(canvas, size);
    _paintMarkers(canvas, size);
    _paintRider(canvas, size);
  }

  void _paintSky(Canvas canvas, Size size) {
    final sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1C2836), Color(0xFF0A0D11)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, sky);
    canvas.drawCircle(
      Offset(size.width * 0.78, size.height * 0.22),
      math.min(18, size.height * 0.08),
      Paint()..color = const Color(0x66FFC857),
    );
  }

  void _paintRidges(Canvas canvas, Size size) {
    _ridge(
      canvas,
      size,
      color: const Color(0xFF1A2433),
      baseline: size.height * 0.50,
      amplitude: size.height * 0.06,
      parallax: 0.04,
    );
    _ridge(
      canvas,
      size,
      color: const Color(0xFF121820),
      baseline: size.height * 0.58,
      amplitude: size.height * 0.045,
      parallax: 0.11,
    );
  }

  void _ridge(
    Canvas canvas,
    Size size, {
    required Color color,
    required double baseline,
    required double amplitude,
    required double parallax,
  }) {
    final shift = (distanceM * parallax) % size.width;
    final path = Path()..moveTo(-20, size.height);
    for (var x = -20.0; x <= size.width + 20; x += 12) {
      final wave = math.sin((x + shift) / 46) * amplitude;
      path.lineTo(x, baseline + wave);
    }
    path
      ..lineTo(size.width + 20, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _paintRoad(Canvas canvas, Size size) {
    final horizon = size.height * 0.58;
    final ground = size.height * 0.90;
    canvas.save();
    final tilt = (gradePct.clamp(-12.0, 12.0)) * math.pi / 180 * 0.55;
    canvas.translate(size.width / 2, ground);
    canvas.rotate(-tilt);
    canvas.translate(-size.width / 2, -ground);

    final road = Path()
      ..moveTo(size.width * 0.38, horizon)
      ..lineTo(size.width * 0.62, horizon)
      ..lineTo(size.width + 8, ground + 8)
      ..lineTo(-8, ground + 8)
      ..close();
    canvas.drawPath(road, Paint()..color = const Color(0xFF232B36));

    final edge = Paint()
      ..color = const Color(0xFF3A4656)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width * 0.38, horizon),
      Offset(-8, ground + 8),
      edge,
    );
    canvas.drawLine(
      Offset(size.width * 0.62, horizon),
      Offset(size.width + 8, ground + 8),
      edge,
    );

    final dash = Paint()
      ..color = const Color(0xFF8A96A4)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.butt;
    const spacing = 2.4;
    final phase = distanceM % spacing;
    for (var i = 0; i < 14; i++) {
      final near = phase + i * spacing;
      final far = near + 1.1;
      final a = _roadPoint(size, horizon, ground, near);
      final b = _roadPoint(size, horizon, ground, far);
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, dash);
    }
    canvas.restore();
  }

  /// Meters ahead of the rider, mapped onto the center line with perspective.
  Offset? _roadPoint(Size size, double horizon, double ground, double meters) {
    const view = 36.0;
    if (meters <= 0 || meters >= view) return null;
    final t = meters / view;
    final depth = 1 - 1 / (1 + t * 5);
    final y = ground - (ground - horizon) * depth;
    return Offset(size.width / 2, y);
  }

  void _paintMarkers(Canvas canvas, Size size) {
    const loop = 400.0;
    const spacing = 50.0;
    final ground = size.height * 0.78;
    for (var i = 0; i < 8; i++) {
      final along = (i * spacing - distanceM) % loop;
      final x = size.width + 30 - (along / loop) * (size.width + 60);
      if (x < -20 || x > size.width + 20) continue;
      final trunk = Rect.fromCenter(
        center: Offset(x, ground - 8),
        width: 3,
        height: 16,
      );
      canvas.drawRect(trunk, Paint()..color = const Color(0xFF3E4A3A));
      final crown = Path()
        ..moveTo(x, ground - 34)
        ..lineTo(x + 12, ground - 10)
        ..lineTo(x - 12, ground - 10)
        ..close();
      canvas.drawPath(crown, Paint()..color = const Color(0xFF2F6B4F));
    }
  }

  void _paintRider(Canvas canvas, Size size) {
    final scale = (size.height / 200).clamp(0.55, 1.4);
    final ground = Offset(size.width * 0.46, size.height * 0.84);
    canvas.save();
    canvas.translate(ground.dx, ground.dy);
    canvas.scale(scale);
    final wheel = distanceM / 0.34;
    _wheel(canvas, const Offset(0, 0), wheel);
    _wheel(canvas, const Offset(78, 0), wheel);
    final frame = Paint()
      ..color = const Color(0xFFE6EDF3)
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const bb = Offset(36, -22);
    const seat = Offset(30, -62);
    const head = Offset(64, -84);
    const bars = Offset(72, -56);
    canvas.drawLine(const Offset(0, 0), bb, frame);
    canvas.drawLine(bb, const Offset(78, 0), frame);
    canvas.drawLine(bb, seat, frame);
    canvas.drawLine(seat, bars, frame);
    canvas.drawLine(bars, const Offset(78, -8), frame);
    canvas.drawCircle(
      seat + const Offset(0, -3),
      3.2,
      Paint()..color = RideColors.textPrimary,
    );
    canvas.drawLine(bars, bars + const Offset(8, -2), frame);

    final hip = seat + const Offset(2, 4);
    final pedalA = bb + Offset(math.cos(crankRad), math.sin(crankRad)) * 15;
    final pedalB =
        bb +
        Offset(math.cos(crankRad + math.pi), math.sin(crankRad + math.pi)) * 15;
    _leg(canvas, hip, pedalA, const Color(0xFF4FC3F7));
    _leg(canvas, hip, pedalB, const Color(0xFF8AD4F8));

    final torso = Paint()
      ..color = const Color(0xFF4FC3F7)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(hip, head + const Offset(0, 10), torso);
    canvas.drawLine(head + const Offset(2, 8), bars, torso..strokeWidth = 3.5);
    canvas.drawCircle(head, 8, Paint()..color = const Color(0xFFF2D3B5));
    canvas.drawArc(
      Rect.fromCircle(center: head + const Offset(1, -1), radius: 8.5),
      math.pi,
      math.pi,
      true,
      Paint()..color = const Color(0xFF243044),
    );
    canvas.restore();
  }

  void _wheel(Canvas canvas, Offset center, double angle) {
    canvas.drawCircle(
      center,
      18,
      Paint()
        ..color = const Color(0xFF0A0D11)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      18,
      Paint()
        ..color = const Color(0xFFD5DDE6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    final spoke = Paint()
      ..color = const Color(0xFF9AA7B5)
      ..strokeWidth = 1.2;
    for (var i = 0; i < 3; i++) {
      final a = angle + i * math.pi / 3;
      canvas.drawLine(
        center + Offset(math.cos(a), math.sin(a)) * 4,
        center + Offset(math.cos(a), math.sin(a)) * 16,
        spoke,
      );
      canvas.drawLine(
        center + Offset(math.cos(a + math.pi), math.sin(a + math.pi)) * 4,
        center + Offset(math.cos(a + math.pi), math.sin(a + math.pi)) * 16,
        spoke,
      );
    }
    canvas.drawCircle(center, 2.4, Paint()..color = RideColors.textPrimary);
  }

  void _leg(Canvas canvas, Offset hip, Offset foot, Color color) {
    final joint = _knee(hip, foot, 28, 28);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(hip, joint, paint);
    canvas.drawLine(joint, foot, paint);
    canvas.drawCircle(foot, 2.4, Paint()..color = const Color(0xFF1A212C));
  }

  Offset _knee(Offset hip, Offset foot, double thigh, double shin) {
    final delta = foot - hip;
    final raw = delta.distance;
    if (raw < 0.001) return Offset(hip.dx, hip.dy - thigh);
    final maxReach = thigh + shin - 0.4;
    final minReach = (thigh - shin).abs() + 0.4;
    final dist = raw.clamp(minReach, maxReach);
    final ux = delta.dx / raw;
    final uy = delta.dy / raw;
    final a = (thigh * thigh - shin * shin + dist * dist) / (2 * dist);
    final height = math.sqrt(math.max(0, thigh * thigh - a * a));
    final mid = hip + Offset(ux, uy) * a;
    final left = mid + Offset(-uy, ux) * height;
    final right = mid + Offset(uy, -ux) * height;
    return left.dy <= right.dy ? left : right;
  }

  @override
  bool shouldRepaint(covariant _RideWorldPainter oldDelegate) {
    return oldDelegate.distanceM != distanceM ||
        oldDelegate.crankRad != crankRad ||
        oldDelegate.gradePct != gradePct;
  }
}
