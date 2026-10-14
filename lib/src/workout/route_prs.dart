import 'dart:convert';
import 'dart:io';

import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

/// Must match `climbs::DETECTOR_VERSION` in Rust. Climb ids depend on the
/// detector, so a stored file from another version is re-keyed (stale ids
/// dropped) on the next write.
const kClimbDetector = 3;

/// One personal record.
class ClimbPr {
  const ClimbPr({
    required this.startM,
    required this.endM,
    required this.gainM,
    required this.bestS,
    required this.setAt,
  });

  final double startM, endM, gainM, bestS;
  final String setAt;

  Map<String, Object?> toJson() => {
    'startM': startM,
    'endM': endM,
    'gainM': gainM,
    'bestS': double.parse(bestS.toStringAsFixed(1)),
    'setAt': setAt,
  };

  static ClimbPr? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['startM'], e = j['endM'], g = j['gainM'], b = j['bestS'];
    if (s is! num || e is! num || g is! num || b is! num || !(b > 0)) {
      return null;
    }
    return ClimbPr(
      startM: s.toDouble(),
      endM: e.toDouble(),
      gainM: g.toDouble(),
      bestS: b.toDouble(),
      setAt: '${j['setAt'] ?? ''}',
    );
  }
}

/// A PR that improved on this ride (for the toast / summary).
class PrImprovement {
  const PrImprovement({required this.label, required this.timeS, this.prevS});
  final String label;
  final double timeS;
  final double? prevS;
}

/// `<routeKey>.prs.json` content.
class RoutePrs {
  RoutePrs({this.routeBestS, Map<String, ClimbPr>? climbs})
    : climbs = climbs ?? {};
  double? routeBestS;
  final Map<String, ClimbPr> climbs;
}

/// Seconds between first crossings of [startM] and [endM] on a ride
/// (route distance, interpolated; mirrors Rust `climbs::climb_time_s`).
double? climbTimeS(
  List<({double d, double t})> track,
  double startM,
  double endM,
) {
  double? cross(double m) {
    for (var j = 0; j < track.length; j++) {
      if (track[j].d >= m) {
        if (j == 0) return track[0].d == m ? track[0].t : null;
        final a = track[j - 1], b = track[j];
        final span = (b.d - a.d).abs() < 1e-9 ? 1e-9 : b.d - a.d;
        return a.t + (m - a.d) / span * (b.t - a.t);
      }
    }
    return null;
  }

  final s = cross(startM), e = cross(endM);
  if (s == null || e == null || e <= s) return null;
  return e - s;
}

/// Local route / climb PRs in `routes/ghosts/<routeKey>.prs.json`, next to
/// the ghost best (step 4, P2). Never written for Demo rides.
class RoutePrStore {
  RoutePrStore(this.dir);
  factory RoutePrStore.of(GhostStore g) => RoutePrStore(g.dir);

  final Directory dir;
  DateTime Function() now = DateTime.now;

  File file(String key) =>
      File('${dir.path}${Platform.pathSeparator}$key.prs.json');

  RoutePrs read(String key) {
    try {
      final j = jsonDecode(file(key).readAsStringSync());
      if (j is! Map || j['v'] != 1) return RoutePrs();
      final rb = j['routeBestS'];
      final out = RoutePrs(
        routeBestS: rb is num && rb > 0 ? rb.toDouble() : null,
      );
      if (j['detector'] == kClimbDetector && j['climbs'] is Map) {
        (j['climbs'] as Map).forEach((id, v) {
          final pr = ClimbPr.fromJson(v);
          if (pr != null) out.climbs['$id'] = pr;
        });
      }
      return out;
    } catch (_) {
      return RoutePrs();
    }
  }

  /// Applies one finished ride; returns what improved (empty when nothing
  /// did, or for Demo). [finishS] is set only for a completed route.
  List<PrImprovement> recordRide({
    required String routeKey,
    required List<Climb> climbs,
    required List<({double d, double t})> track,
    required bool isDemo,
    double? finishS,
  }) {
    if (isDemo) return const [];
    // Non-finite samples would make "PR = NaN" (QA c7 P2-e).
    track = [
      for (final p in track)
        if (p.d.isFinite && p.t.isFinite) p,
    ];
    if (track.length < 2) return const [];
    final corrupt = _isCorrupt(routeKey);
    final prs = read(routeKey);
    final stamp = now().toUtc().toIso8601String();
    final out = <PrImprovement>[];
    final valid = {for (final c in climbs) c.id};
    prs.climbs.removeWhere((id, _) => !valid.contains(id));
    for (final c in climbs) {
      final t = climbTimeS(track, c.startM, c.endM);
      if (t == null || !t.isFinite || t <= 0) continue;
      final prev = prs.climbs[c.id];
      if (prev == null || t < prev.bestS) {
        prs.climbs[c.id] = ClimbPr(
          startM: c.startM,
          endM: c.endM,
          gainM: c.gainM,
          bestS: t,
          setAt: stamp,
        );
        out.add(
          PrImprovement(
            label:
                'Climb ${(c.startM / 1000).toStringAsFixed(1)}–'
                '${(c.endM / 1000).toStringAsFixed(1)} km '
                '(+${c.gainM.round()} m)',
            timeS: t,
            prevS: prev?.bestS,
          ),
        );
      }
    }
    if (finishS != null && finishS.isFinite && finishS > 0) {
      final prev = prs.routeBestS;
      if (prev == null || finishS < prev) {
        prs.routeBestS = finishS;
        out.add(PrImprovement(label: 'Route', timeS: finishS, prevS: prev));
      }
    }
    if (out.isEmpty) return out;
    // A corrupt file may hold faster PRs: keep it aside (QA c7 P2-d).
    if (corrupt) {
      try {
        file(routeKey).renameSync(
          '${file(routeKey).path}.corrupt-${now().millisecondsSinceEpoch}',
        );
      } catch (_) {
        return const [];
      }
    }
    // Only claim PRs that were actually stored.
    return _write(routeKey, prs) ? out : const [];
  }

  /// The file exists but isn't a readable v1 PR file.
  bool _isCorrupt(String key) {
    final f = file(key);
    if (!f.existsSync()) return false;
    try {
      final j = jsonDecode(f.readAsStringSync());
      return j is! Map || j['v'] != 1;
    } catch (_) {
      return true;
    }
  }

  bool _write(String key, RoutePrs p) {
    try {
      dir.createSync(recursive: true);
      final tmp = File('${file(key).path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'v': 1,
          'detector': kClimbDetector,
          'routeKey': key,
          if (p.routeBestS != null)
            'routeBestS': double.parse(p.routeBestS!.toStringAsFixed(1)),
          'climbs': {for (final e in p.climbs.entries) e.key: e.value.toJson()},
        }),
        flush: true,
      );
      tmp.renameSync(file(key).path);
      return true;
    } catch (_) {
      return false;
    }
  }
}
