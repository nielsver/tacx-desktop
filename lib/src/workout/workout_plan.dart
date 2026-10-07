import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// One planned step of a structured workout, parsed from the JSON that
/// `load_workout_json` returns (same schema as `*.tacxworkout.json`).
@immutable
class PlanStep {
  const PlanStep({
    required this.kind,
    required this.durationS,
    this.startW,
    this.endW,
    this.gradePct,
    this.resistancePct,
  });

  /// erg | ramp | resistance | simGrade
  final String kind;

  /// Effective duration. The Rust engine runs every step for at least 1 s.
  final int durationS;

  /// Target watts at the start / end of the step (equal for ERG steps,
  /// null for resistance / simGrade steps).
  final int? startW;
  final int? endW;
  final double? gradePct;
  final double? resistancePct;

  bool get hasPower => startW != null;
  bool get isRamp => kind == 'ramp';

  /// Target watts [t] seconds into this step (linear for ramps).
  double? targetAt(double t) {
    final a = startW, b = endW;
    if (a == null) return null;
    if (b == null || b == a) return a.toDouble();
    final f = (t / math.max(1, durationS)).clamp(0.0, 1.0);
    return a + (b - a) * f;
  }

  /// Short human label: "230 W", "120→150 W", "4.0 %", "Res 20 %".
  String get targetLabel {
    switch (kind) {
      case 'ramp':
        return '$startW→$endW W';
      case 'erg':
        return '$startW W';
      case 'simGrade':
        return '${(gradePct ?? 0).toStringAsFixed(1)} %';
      case 'resistance':
        return 'Res ${(resistancePct ?? 0).toStringAsFixed(0)} %';
      default:
        return kind;
    }
  }

  static PlanStep fromMap(Map<String, dynamic> m) {
    final kind = (m['kind'] as String?) ?? 'erg';
    final dur = ((m['durationS'] as num?)?.toInt() ?? 0).clamp(1, 1 << 30);
    int? asInt(Object? v) => (v as num?)?.round();
    double? asDouble(Object? v) => (v as num?)?.toDouble();
    switch (kind) {
      case 'ramp':
        return PlanStep(
          kind: kind,
          durationS: dur,
          // Same fallbacks as the Rust engine.
          startW: asInt(m['wattsStart']) ?? 100,
          endW: asInt(m['wattsEnd']) ?? 150,
        );
      case 'erg':
        final w = asInt(m['watts']) ?? 0;
        return PlanStep(kind: kind, durationS: dur, startW: w, endW: w);
      case 'simGrade':
        return PlanStep(
          kind: kind,
          durationS: dur,
          gradePct: asDouble(m['gradePct']) ?? 0,
        );
      case 'resistance':
        return PlanStep(
          kind: kind,
          durationS: dur,
          resistancePct: asDouble(m['resistancePct']) ?? 20,
        );
      default:
        return PlanStep(kind: kind, durationS: dur);
    }
  }
}

/// A whole planned workout with a cumulative time axis.
@immutable
class WorkoutPlan {
  WorkoutPlan({required this.id, required this.name, required this.steps})
    : _starts = _cumulative(steps);

  final String id;
  final String name;
  final List<PlanStep> steps;
  final List<int> _starts;

  static List<int> _cumulative(List<PlanStep> steps) {
    final out = <int>[];
    var t = 0;
    for (final s in steps) {
      out.add(t);
      t += s.durationS;
    }
    out.add(t);
    return List.unmodifiable(out);
  }

  /// Total planned duration in seconds.
  int get totalS => _starts.last;

  /// Second at which step [i] starts (i == steps.length → total).
  int startOf(int i) => _starts[i.clamp(0, steps.length)];

  /// Highest planned watts (0 when the plan has no power steps).
  int get maxWatts => steps.fold<int>(
    0,
    (m, s) => math.max(m, math.max(s.startW ?? 0, s.endW ?? 0)),
  );

  /// Index of the step that is active at [t] seconds into the workout.
  int stepIndexAt(double t) {
    if (steps.isEmpty) return 0;
    for (var i = 0; i < steps.length; i++) {
      if (t < _starts[i + 1]) return i;
    }
    return steps.length - 1;
  }

  /// Planned target watts at [t] seconds (null on non-power steps).
  double? targetAt(double t) {
    if (steps.isEmpty) return null;
    final i = stepIndexAt(t);
    return steps[i].targetAt(t - _starts[i]);
  }

  /// Workout-relative elapsed seconds from the engine's step index and the
  /// time left in that step.
  double elapsedFrom({
    required int stepIndex,
    required double remainingS,
    bool done = false,
  }) {
    if (steps.isEmpty) return 0;
    if (done) return totalS.toDouble();
    final i = stepIndex.clamp(0, steps.length - 1);
    final dur = steps[i].durationS.toDouble();
    final inStep = (dur - remainingS.clamp(0.0, dur)).clamp(0.0, dur);
    return _starts[i] + inStep;
  }

  /// Parses the JSON from `load_workout_json`. Returns null on bad input.
  static WorkoutPlan? tryParse(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      final raw = (m['steps'] as List?) ?? const [];
      return WorkoutPlan(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        steps: List.unmodifiable(
          raw.whereType<Map<String, dynamic>>().map(PlanStep.fromMap),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Coggan power zone (1–7) for [watts] given [ftp].
int powerZone(double watts, int ftp) {
  final pct = watts / math.max(1, ftp) * 100;
  if (pct < 55) return 1;
  if (pct < 76) return 2;
  if (pct < 91) return 3;
  if (pct < 106) return 4;
  if (pct < 121) return 5;
  if (pct < 151) return 6;
  return 7;
}

/// Calm zone palette (Z1 grey-blue … Z7 violet), used for planned blocks.
const List<Color> kZoneColors = [
  Color(0xFF7E8A97), // Z1 recovery
  Color(0xFF4FA3E0), // Z2 endurance
  Color(0xFF4DB88A), // Z3 tempo
  Color(0xFFE2BE4A), // Z4 threshold
  Color(0xFFEE8A4B), // Z5 VO2max
  Color(0xFFE25B5B), // Z6 anaerobic
  Color(0xFFB06BD9), // Z7 neuromuscular
];

/// Neutral colour for steps without a power target (sim grade / resistance).
const Color kNonPowerStepColor = Color(0xFF5B6B7C);

Color zoneColor(int zone) => kZoneColors[(zone - 1).clamp(0, 6)];

/// 3-2-1 countdown value shown before a step change, or null.
///
/// Returns 3, 2 or 1 while [remainingS] is in (0, [from]] and another step
/// follows ([hasNext]); null otherwise. Uses ceil so "3" is visible for the
/// whole last-three-seconds window's first second.
int? stepCountdown(double remainingS, {required bool hasNext, int from = 3}) {
  if (!hasNext || !remainingS.isFinite) return null;
  if (remainingS <= 0 || remainingS > from) return null;
  return remainingS.ceil().clamp(1, from);
}

/// "m:ss" or "h:mm:ss" for a non-negative number of seconds.
String fmtClock(num seconds) {
  final s = seconds.isFinite ? seconds.round().clamp(0, 1 << 30) : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// 1 Hz actual-power trace on the workout time axis (for the ride graph).
///
/// [points] is a live read-only view (no copy per frame); painters compare
/// [version] to decide whether to repaint.
class WorkoutTrace extends ChangeNotifier {
  String _workoutId = '';
  final List<({double t, double watts})> _points = [];
  late final UnmodifiableListView<({double t, double watts})> _view =
      UnmodifiableListView(_points);
  int _version = 0;

  String get workoutId => _workoutId;
  UnmodifiableListView<({double t, double watts})> get points => _view;
  int get length => _points.length;

  /// Bumped on every change (append / reset / clear).
  int get version => _version;

  /// Records [watts] at workout time [t]. Keeps ≥ [minGapS] between points,
  /// and restarts the trace when the workout id changes or time jumps back
  /// (the same workout was restarted). Non-finite watts are dropped (a
  /// missing sample is better than a fake 0 W dip).
  bool offer(String workoutId, double t, double watts, {double minGapS = 1}) {
    if (!t.isFinite || !watts.isFinite) return false;
    if (workoutId != _workoutId ||
        (_points.isNotEmpty && t + 0.5 < _points.last.t)) {
      // 0.5 s tolerance so poll jitter never resets the trace.
      _workoutId = workoutId;
      _points.clear();
      _version++;
    }
    if (_points.isNotEmpty && t - _points.last.t < minGapS) return false;
    _points.add((t: t, watts: math.max(0, watts)));
    _version++;
    notifyListeners();
    return true;
  }

  void clear() {
    if (_points.isEmpty && _workoutId.isEmpty) return;
    _points.clear();
    _workoutId = '';
    _version++;
    notifyListeners();
  }
}

/// Min/max decimation for line plots: at most [maxPoints] points, keeping
/// each bucket's lowest and highest sample (in time order) so short sprints
/// and dips stay visible on long rides.
List<({double t, double watts})> decimateMinMax(
  List<({double t, double watts})> pts,
  int maxPoints,
) {
  if (maxPoints < 4 || pts.length <= maxPoints) return pts;
  final buckets = maxPoints ~/ 2;
  final out = <({double t, double watts})>[];
  final per = pts.length / buckets;
  for (var b = 0; b < buckets; b++) {
    final lo = (b * per).floor();
    final hi = math.min(pts.length, ((b + 1) * per).floor());
    if (hi <= lo) continue;
    var iMin = lo, iMax = lo;
    for (var i = lo + 1; i < hi; i++) {
      if (pts[i].watts < pts[iMin].watts) iMin = i;
      if (pts[i].watts > pts[iMax].watts) iMax = i;
    }
    if (iMin == iMax) {
      out.add(pts[iMin]);
    } else if (iMin < iMax) {
      out..add(pts[iMin])..add(pts[iMax]);
    } else {
      out..add(pts[iMax])..add(pts[iMin]);
    }
  }
  return out;
}
