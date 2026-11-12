import 'dart:math' as math;

/// Steady-state Martin/Coggan speed for the on-screen world.
///
/// Keep this in step with `rust/src/trainer/physics.rs`. The Flutter bridge
/// was not regenerated: codegen 2.13.0 rewrote the generated files in place.
/// Trainer wheel speed and TCX export do not use this value.
const defaultRiderMassKg = 83.0;

const _rho = 1.2;
const _cda = 0.32;
const _crr = 0.004;
const _eta = 0.97;
const _g = 9.80665;
const _aero = 0.5 * _rho * _cda;
const _maxSpeedMps = 40.0;

double virtualSpeedMps({
  required double powerW,
  required double gradePct,
  required double massKg,
}) {
  if (!powerW.isFinite || powerW <= 0) return 0;
  final grade = gradePct.isFinite ? gradePct : 0.0;
  final mass = massKg.isFinite && massKg > 0 ? massKg : defaultRiderMassKg;
  final wheel = powerW * _eta;
  final resist = mass * _g * (_crr + math.sin(math.atan(grade / 100)));
  var speed = math
      .pow(wheel / _aero, 1 / 3)
      .toDouble()
      .clamp(0.0, _maxSpeedMps);
  for (var i = 0; i < 8; i++) {
    final slope = 3 * _aero * speed * speed + resist;
    if (!slope.isFinite || slope.abs() < 1e-12) break;
    final next =
        speed -
        (_aero * speed * speed * speed + resist * speed - wheel) / slope;
    if (!next.isFinite) break;
    final clamped = next.clamp(0.0, _maxSpeedMps);
    if ((clamped - speed).abs() < 1e-4) {
      speed = clamped;
      break;
    }
    speed = clamped;
  }
  if (!speed.isFinite) return 0;
  return speed.clamp(0.0, _maxSpeedMps);
}
