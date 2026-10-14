import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tacx_desktop/src/rust/trainer/types.dart';

/// Legacy (v1) route id: FNV-1a 64 over the rounded elevation profile.
///
/// Superseded by the Rust `route_key` (v2, lat/lon based; see `gpx.rs`),
/// because flat or re-sampled routes collided / drifted (QA G5). Kept only
/// to find bests saved by 155eeba.
String legacyRouteKey(GpxProfileInfo p) {
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

  /// Longest ghost accepted from disk / a .tdshare: 12 h at 1 Hz (the
  /// recorder's own limit) plus slack.
  static const int maxPoints = 50000;

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
    if (d.length > maxPoints) return null;
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

  /// Adds the finish point: the distance actually reported at time [t]
  /// (never the route length by fiat, so coverage checks stay honest, G4).
  void finish(double t, double reportedM) {
    if (!t.isFinite || !reportedM.isFinite) return;
    if (_points.isNotEmpty && t < _points.last.t) t = _points.last.t;
    _points.add((d: math.max(reportedM, lastD), t: t));
  }

  double get firstD => _points.isEmpty ? 0 : _points.first.d;

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

/// Why an attempt is not a valid ghost for a route (null = valid).
///
/// Valid = starts within max(50 m, 1 %) of the route start, covers ≥ 98 %
/// of the route, and is not faster than 30 m/s on average (G1/G4).
String? ghostProblem(GhostTrack g, double routeDistanceM) {
  if (g.isEmpty) return 'empty';
  if (!(routeDistanceM > 0)) return 'no route distance';
  final first = g.points.first, last = g.points.last;
  if (first.d > math.max(50, routeDistanceM * 0.01)) {
    return 'starts ${first.d.round()} m into the route';
  }
  if (last.d - first.d < routeDistanceM * 0.98) return 'incomplete';
  if (last.t - first.t < routeDistanceM / 30) return 'implausibly fast';
  return null;
}

/// Ghost file format (v2, aligned with the `.tdshare` bundle in
/// docs/multiplayer.md): self-describing, versioned, no GPS, no HR,
/// no wall-clock time (date only).
class GhostFile {
  GhostFile({
    required this.routeKey,
    required this.routeName,
    required this.distanceM,
    required this.track,
    this.legacyKey,
    this.sampleIntervalS = 1,
    this.riderName = '',
    this.demo = false,
    this.verified = false,
    String? createdDate,
  }) : createdDate = createdDate ?? _today();

  static const int version = 2;
  static const String kind = 'ghost';

  final String routeKey;
  final String? legacyKey;
  final String routeName;
  final double distanceM;
  final GhostTrack track;
  final double sampleIntervalS;

  /// Placeholder until profiles exist (step 5): shown next to a friend's ghost.
  final String riderName;
  final bool demo;
  final bool verified;
  final String createdDate;

  double get totalS => track.totalS;

  static String _today() =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);

  Map<String, dynamic> toJson() => {
    'v': version,
    'kind': kind,
    'routeKeyV2': routeKey,
    'routeKeyV1': legacyKey,
    'routeName': routeName,
    'distanceM': double.parse(distanceM.toStringAsFixed(1)),
    'totalS': double.parse(totalS.toStringAsFixed(1)),
    'sampleIntervalS': sampleIntervalS,
    'track': track.toJson(),
    'rider': {'displayName': riderName},
    'app': 'tacx-desktop',
    'verified': verified,
    'demo': demo,
    'createdDate': createdDate,
  };

  /// Strict parse. Throws [FormatException] with a user-facing reason.
  /// [expectKey]: the file must be for this route (v2 key, or the legacy key
  /// for v1 files). [routeDistanceM]: distance must match within 1 % and
  /// the track must be a valid ghost for it.
  static GhostFile parse(
    Object? json, {
    String? expectKey,
    double? routeDistanceM,
  }) {
    if (json is! Map) throw const FormatException('not a ghost file');
    final GhostFile f;
    if (json['v'] == 2 && json['kind'] == kind) {
      final track = GhostTrack.fromJson(json['track']);
      final key = json['routeKeyV2'];
      final dist = json['distanceM'];
      if (track == null || key is! String || dist is! num) {
        throw const FormatException('malformed ghost file');
      }
      final rider = json['rider'];
      f = GhostFile(
        routeKey: key,
        legacyKey: json['routeKeyV1'] as String?,
        routeName: (json['routeName'] as String?) ?? '',
        distanceM: dist.toDouble(),
        track: track,
        sampleIntervalS: (json['sampleIntervalS'] as num?)?.toDouble() ?? 1,
        riderName: rider is Map ? (rider['displayName'] as String? ?? '') : '',
        demo: json['demo'] == true,
        verified: false, // files are never verified (multiplayer.md §4)
        createdDate: json['createdDate'] as String?,
      );
    } else if (json['version'] == 1) {
      // 155eeba best file: {version:1, routeKey (legacy), routeName, ...}.
      final track = GhostTrack.fromJson(json['track']);
      final key = json['routeKey'];
      final dist = json['distanceM'];
      if (track == null || key is! String || dist is! num) {
        throw const FormatException('malformed v1 ghost file');
      }
      f = GhostFile(
        routeKey: key,
        legacyKey: key,
        routeName: (json['routeName'] as String?) ?? '',
        distanceM: dist.toDouble(),
        track: track,
      );
    } else {
      throw FormatException('unsupported ghost version ${json['v'] ?? json['version']}');
    }
    if (expectKey != null && f.routeKey != expectKey && f.legacyKey != expectKey) {
      throw const FormatException('ghost is for a different route');
    }
    if (routeDistanceM != null) {
      if ((f.distanceM - routeDistanceM).abs() > routeDistanceM * 0.01) {
        throw const FormatException('ghost route length does not match');
      }
      final why = ghostProblem(f.track, routeDistanceM);
      if (why != null) throw FormatException('invalid ghost: $why');
    }
    return f;
  }
}

/// Result of reading a best file: missing, readable, or present but
/// unreadable (then it must never be overwritten silently, G6).
sealed class GhostRead {
  const GhostRead();
}

class GhostMissing extends GhostRead {
  const GhostMissing();
}

class GhostOk extends GhostRead {
  const GhostOk(this.file);
  final GhostFile file;
}

class GhostUnreadable extends GhostRead {
  const GhostUnreadable(this.reason);
  final String reason;
}

/// Best attempt per route, as small versioned JSON files:
/// `<dir>/<routeKey>.best.json`, by default
/// `Documents/Tacx Desktop/routes/ghosts/` (next to `workouts/`).
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

  /// Tests point the dashboard's store at a temp dir with this, so they
  /// never touch the real `~/Documents/Tacx Desktop` (QA G9).
  static Directory? debugDirOverride;

  /// Clock for corrupt-file names (overridable in tests).
  DateTime Function() now = DateTime.now;

  File bestFile(String key) =>
      File('${dir.path}${Platform.pathSeparator}$key.best.json');

  /// Reads the best file for [key] without validating it against a route.
  GhostRead read(String key) {
    final f = bestFile(key);
    final String raw;
    try {
      final type = FileSystemEntity.typeSync(f.path);
      if (type == FileSystemEntityType.notFound) return const GhostMissing();
      if (type != FileSystemEntityType.file) {
        return GhostUnreadable('not a file: ${f.path}');
      }
      raw = f.readAsStringSync();
    } catch (e) {
      return GhostUnreadable('$e'); // locked / permission: leave it alone
    }
    try {
      return GhostOk(GhostFile.parse(jsonDecode(raw), expectKey: key));
    } catch (_) {
      // Corrupt or foreign content: move it aside (kept for inspection).
      try {
        final ts = now().toUtc().millisecondsSinceEpoch;
        f.renameSync('${f.path}.corrupt-$ts');
        return const GhostMissing();
      } catch (e) {
        return GhostUnreadable('$e');
      }
    }
  }

  /// The valid stored best for [key] on a route of [routeDistanceM] (when
  /// given), else null.
  GhostFile? loadFile(String key, {double? routeDistanceM}) {
    final r = read(key);
    if (r is! GhostOk) return null;
    final f = r.file;
    if (routeDistanceM != null) {
      if ((f.distanceM - routeDistanceM).abs() > routeDistanceM * 0.01) {
        return null;
      }
      if (ghostProblem(f.track, routeDistanceM) != null) return null;
    }
    return f;
  }

  GhostTrack? load(String key, {double? routeDistanceM}) =>
      loadFile(key, routeDistanceM: routeDistanceM)?.track;

  /// Best for a loaded GPX: the v2 key first, then the legacy (155eeba) key.
  /// A legacy best is migrated to v2 only when its distance is within 1 %
  /// and its route name matches (guards against old flat-route collisions).
  GhostFile? loadForRoute({
    required String key,
    required String legacyKey,
    required String routeName,
    required double distanceM,
  }) {
    final v2 = loadFile(key, routeDistanceM: distanceM);
    if (v2 != null) return v2;
    if (read(key) is GhostUnreadable) return null;
    final old = loadFile(legacyKey, routeDistanceM: distanceM);
    if (old == null || old.routeName != routeName) return null;
    final migrated = GhostFile(
      routeKey: key,
      legacyKey: legacyKey,
      routeName: old.routeName,
      distanceM: old.distanceM,
      track: old.track,
      createdDate: old.createdDate,
    );
    _write(key, migrated); // the old file is kept
    return migrated;
  }

  /// Saves [attempt] when it is a valid ghost for the route and beats the
  /// stored best. Never in Demo (synthetic speed, G2), never over a file it
  /// can't read (G6). Returns true when it became the new best.
  bool saveIfBest(
    String key,
    String routeName,
    double routeDistanceM,
    GhostTrack attempt, {
    String? legacyKey,
    bool isDemo = false,
  }) {
    if (isDemo) return false;
    if (ghostProblem(attempt, routeDistanceM) != null) return false;
    final prev = read(key);
    if (prev is GhostUnreadable) return false;
    if (prev is GhostOk &&
        ghostProblem(prev.file.track, routeDistanceM) == null &&
        prev.file.totalS <= attempt.totalS) {
      return false;
    }
    return _write(
      key,
      GhostFile(
        routeKey: key,
        legacyKey: legacyKey,
        routeName: routeName,
        distanceM: routeDistanceM,
        track: attempt,
      ),
    );
  }

  /// Deletes the stored best for [key] ("Reset best"). True if one existed.
  bool resetBest(String key) {
    try {
      final f = bestFile(key);
      if (!f.existsSync()) return false;
      f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _write(String key, GhostFile g) {
    try {
      dir.createSync(recursive: true);
      final tmp = File('${bestFile(key).path}.tmp');
      tmp.writeAsStringSync(jsonEncode(g.toJson()), flush: true);
      tmp.renameSync(bestFile(key).path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Writes the best for [key] as a `.tdshare` bundle (gzipped ghost JSON)
  /// to [dest]. Refuses demo ghosts. Returns the file, or null.
  File? exportShare(String key, File dest, {String riderName = ''}) {
    final r = read(key);
    if (r is! GhostOk || r.file.demo) return null;
    final f = r.file;
    final out = GhostFile(
      routeKey: f.routeKey,
      legacyKey: f.legacyKey,
      routeName: f.routeName,
      distanceM: f.distanceM,
      track: f.track,
      sampleIntervalS: f.sampleIntervalS,
      riderName: riderName,
      createdDate: f.createdDate,
    );
    try {
      dest.parent.createSync(recursive: true);
      dest.writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(out.toJson()))), flush: true);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// Max `.tdshare` size (multiplayer.md: strict, ≤ 1 MB).
  static const int maxShareBytes = 1 << 20;

  /// Cap on the *decompressed* .tdshare JSON. A 50k-point ghost is ~1 MB;
  /// a gzip bomb stops here instead of expanding to hundreds of MB.
  static const int maxShareDecodedBytes = 4 << 20;

  /// Gunzips [bytes], failing as soon as the output passes [cap]. Input is
  /// fed in 1 KB slices so one slice can overshoot by at most ~1 MB.
  static List<int> gunzipCapped(List<int> bytes, int cap) {
    final sink = _CappedSink(cap);
    final input = gzip.decoder.startChunkedConversion(sink);
    const slice = 1024;
    for (var i = 0; i < bytes.length; i += slice) {
      input.add(bytes.sublist(i, math.min(i + slice, bytes.length)));
    }
    input.close();
    return sink.bytes.takeBytes();
  }

  /// Reads a `.tdshare` bundle for the route [key] / [routeDistanceM] and
  /// stores it as a friend ghost (`<key>.friend-<slug>.json`). Throws
  /// [FormatException] on version / route mismatch, demo or invalid data.
  GhostFile importShare(File src, {required String key, required double routeDistanceM}) {
    final bytes = src.readAsBytesSync();
    if (bytes.length > maxShareBytes) {
      throw const FormatException('file too large');
    }
    final Object? json;
    try {
      json = jsonDecode(
        utf8.decode(gunzipCapped(bytes, maxShareDecodedBytes)),
      );
    } on _TooLarge {
      throw const FormatException('ghost file expands too large');
    } catch (_) {
      throw const FormatException('not a .tdshare file');
    }
    if (json is Map && json['v'] != GhostFile.version) {
      throw FormatException('unsupported ghost version ${json['v']}');
    }
    final g = GhostFile.parse(json, expectKey: key, routeDistanceM: routeDistanceM);
    if (g.demo) throw const FormatException('demo ghosts cannot be shared');
    final slug = g.riderName.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    final name = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    final file = File(
      '${dir.path}${Platform.pathSeparator}$key.friend-${name.isEmpty ? 'anon' : name}.json',
    );
    dir.createSync(recursive: true);
    // Atomic like the best file: a crash never leaves half a friend ghost.
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(g.toJson()), flush: true);
    tmp.renameSync(file.path);
    return g;
  }
}

class _TooLarge implements Exception {
  const _TooLarge();
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.cap);
  final int cap;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > cap) throw const _TooLarge();
    bytes.add(chunk);
  }

  @override
  void close() {}
}
