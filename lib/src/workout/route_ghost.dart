import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tacx_desktop/src/rust/trainer/types.dart';

/// Stable id for a GPX route: FNV-1a 64 over the rounded elevation profile
/// (distance + elevation), so the same file (or a re-export of it) maps to
/// the same best attempt regardless of its track name.
String routeKey(GpxProfileInfo p) {
  var h = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  void mix(int v) {
    for (var i = 0; i < 4; i++) {
      h ^= (v >> (8 * i)) & 0xff;
      h = (h * prime) & 0xFFFFFFFFFFFFFFFF;
    }
  }

  mix(p.distanceM.round());
  mix(p.samples.length);
  for (final s in p.samples) {
    mix(s.distanceM.round());
    mix((s.elevM * 10).round());
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// One ride over a route as time-vs-distance points (both non-decreasing).
class GhostTrack {
  GhostTrack(List<({double d, double t})> points)
    : points = List.unmodifiable(points);

  final List<({double d, double t})> points;

  bool get isEmpty => points.length < 2;
  double get totalS => points.isEmpty ? 0 : points.last.t;
  double get distanceM => points.isEmpty ? 0 : points.last.d;

  /// Seconds this attempt needed to reach [d] metres (linear interpolation).
  double? timeAt(double d) => _interp(d, (p) => p.d, (p) => p.t);

  /// Metres this attempt had covered after [t] seconds.
  double? distanceAt(double t) => _interp(t, (p) => p.t, (p) => p.d);

  double? _interp(
    double x,
    double Function(({double d, double t})) xs,
    double Function(({double d, double t})) ys,
  ) {
    if (isEmpty || !x.isFinite) return null;
    if (x <= xs(points.first)) return ys(points.first);
    if (x >= xs(points.last)) return ys(points.last);
    var lo = 0, hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (xs(points[mid]) <= x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = points[lo], b = points[hi];
    final span = xs(b) - xs(a);
    if (span <= 0) return ys(b);
    return ys(a) + (ys(b) - ys(a)) * ((x - xs(a)) / span);
  }

  Map<String, dynamic> toJson() => {
    'd': [for (final p in points) double.parse(p.d.toStringAsFixed(1))],
    't': [for (final p in points) double.parse(p.t.toStringAsFixed(1))],
  };

  /// Null on malformed input (mismatched / non-numeric / decreasing data).
  static GhostTrack? fromJson(Object? json) {
    if (json is! Map) return null;
    final d = json['d'], t = json['t'];
    if (d is! List || t is! List || d.length != t.length || d.length < 2) {
      return null;
    }
    final pts = <({double d, double t})>[];
    for (var i = 0; i < d.length; i++) {
      final di = d[i], ti = t[i];
      if (di is! num || ti is! num) return null;
      final p = (d: di.toDouble(), t: ti.toDouble());
      if (!p.d.isFinite || !p.t.isFinite) return null;
      if (pts.isNotEmpty && (p.d < pts.last.d || p.t < pts.last.t)) {
        return null;
      }
      pts.add(p);
    }
    return GhostTrack(pts);
  }
}

/// Records the live attempt: one point per second of route time, distance
/// never moving backwards.
class AttemptRecorder {
  final List<({double d, double t})> _points = [];

  int get length => _points.length;
  double get lastT => _points.isEmpty ? 0 : _points.last.t;

  void reset() => _points.clear();

  bool offer(double t, double d, {double minGapS = 1}) {
    if (!t.isFinite || !d.isFinite || t < 0 || d < 0) return false;
    if (_points.isNotEmpty) {
      if (t - _points.last.t < minGapS) return false;
      d = math.max(d, _points.last.d);
    }
    _points.add((d: d, t: t));
    return true;
  }

  /// Adds the finish point (exact route distance at time [t]).
  void finish(double t, double distanceM) {
    if (_points.isNotEmpty && t < _points.last.t) t = _points.last.t;
    _points.add((d: math.max(distanceM, lastD), t: t));
  }

  double get lastD => _points.isEmpty ? 0 : _points.last.d;

  GhostTrack toTrack() => GhostTrack(List.of(_points));
}

/// Seconds behind (+) or ahead (−) of [best] at distance [d] / time [t].
double? ghostDeltaS(GhostTrack best, double d, double t) {
  final bt = best.timeAt(d);
  if (bt == null || !t.isFinite) return null;
  return t - bt;
}

/// "+0:12", "−1:05" or "±0:00" (U+2212 minus for alignment).
String fmtDelta(double s) {
  final r = s.round();
  if (r == 0) return '±0:00';
  final a = r.abs();
  return '${r > 0 ? '+' : '−'}${a ~/ 60}:${(a % 60).toString().padLeft(2, '0')}';
}

/// Best attempt per route, stored as small JSON files:
/// `Documents/Tacx Desktop/routes/ghosts/<routeKey>.best.json`
/// (next to the `workouts/` folder).
class GhostStore {
  GhostStore(this.dir);

  /// Store beside the Rust workouts folder (`.../Tacx Desktop/workouts`).
  factory GhostStore.besideWorkouts(String workoutsDir) => GhostStore(
    Directory(
      '${Directory(workoutsDir).parent.path}${Platform.pathSeparator}routes'
      '${Platform.pathSeparator}ghosts',
    ),
  );

  final Directory dir;

  File _file(String key) =>
      File('${dir.path}${Platform.pathSeparator}$key.best.json');

  /// The stored best for [key], or null if none / unreadable.
  GhostTrack? load(String key) {
    try {
      final f = _file(key);
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync());
      if (m is! Map) return null;
      return GhostTrack.fromJson(m['track']);
    } catch (_) {
      return null;
    }
  }

  /// Saves [attempt] when it covers the route ([routeDistanceM], 98 %) and
  /// beats the stored best. Returns true when it became the new best.
  bool saveIfBest(
    String key,
    String routeName,
    double routeDistanceM,
    GhostTrack attempt,
  ) {
    if (attempt.isEmpty || routeDistanceM <= 0) return false;
    if (attempt.distanceM < routeDistanceM * 0.98) return false;
    if (attempt.totalS <= 0) return false;
    final prev = load(key);
    if (prev != null && prev.totalS <= attempt.totalS) return false;
    try {
      dir.createSync(recursive: true);
      final tmp = File('${_file(key).path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'routeKey': key,
          'routeName': routeName,
          'distanceM': routeDistanceM,
          'totalS': attempt.totalS,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'track': attempt.toJson(),
        }),
      );
      tmp.renameSync(_file(key).path);
      return true;
    } catch (_) {
      return false;
    }
  }
}
