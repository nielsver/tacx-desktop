import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

GpxProfileInfo _profile({
  String name = 'Climb',
  double bump = 0,
  double lat0 = 50,
  String routeKey = 'v2-0000000000000001',
}) => GpxProfileInfo(
  name: name,
  distanceM: 1000,
  elevGainM: 50,
  routeKey: routeKey,
  climbs: const [],
  samples: [
    for (var i = 0; i <= 10; i++)
      ElevSample(
        distanceM: i * 100.0,
        elevM: 100 + i * 5.0 + (i == 5 ? bump : 0),
        gradePct: 5,
        lat: lat0 + i * 0.0009,
        lon: 4,
      ),
  ],
);

/// Constant-speed attempt: [speed] m/s over 1000 m.
GhostTrack _steady(double speed) {
  final r = AttemptRecorder();
  for (var t = 0.0; t * speed < 1000; t += 1) {
    r.offer(t, t * speed);
  }
  r.finish(1000 / speed, 1000);
  return r.toTrack();
}

void main() {
  group('legacyRouteKey (v1 fallback only)', () {
    test('stable for the same profile, ignores the track name', () {
      expect(legacyRouteKey(_profile()), legacyRouteKey(_profile(name: 'Other')));
      expect(legacyRouteKey(_profile()).length, 16);
    });
    test('the v1 flaw: two flat routes in different places collide', () {
      // Why v2 (Rust, lat/lon) exists — see gpx.rs route_key_v2 tests.
      expect(
        legacyRouteKey(_profile(lat0: 50)),
        legacyRouteKey(_profile(lat0: 10)),
      );
    });
  });

  group('GhostTrack', () {
    test('interpolates time at distance and distance at time', () {
      final g = _steady(5); // 200 s total
      expect(g.totalS, closeTo(200, 1e-9));
      expect(g.timeAt(500), closeTo(100, 1e-9));
      expect(g.distanceAt(50), closeTo(250, 1e-9));
      expect(g.timeAt(-10), 0); // clamps
      expect(g.distanceAt(9999), 1000);
      expect(g.timeAt(double.nan), isNull);
    });

    test('JSON round-trip and malformed input', () {
      final g = _steady(4);
      final back = GhostTrack.fromJson(jsonDecode(jsonEncode(g.toJson())))!;
      expect(back.totalS, closeTo(g.totalS, 0.05));
      expect(GhostTrack.fromJson(null), isNull);
      expect(
        GhostTrack.fromJson({
          'd': [0, 1],
          't': [0],
        }),
        isNull,
      );
      expect(
        GhostTrack.fromJson({
          'd': [0, 'x'],
          't': [0, 1],
        }),
        isNull,
      );
      // Distance going backwards is rejected.
      expect(
        GhostTrack.fromJson({
          'd': [0, 10, 5],
          't': [0, 1, 2],
        }),
        isNull,
      );
      expect(
        GhostTrack.fromJson({
          'd': [0],
          't': [0],
        }),
        isNull,
      );
    });
  });

  group('AttemptRecorder', () {
    test('1 Hz, distance never moves backwards, ignores bad samples', () {
      final r = AttemptRecorder();
      expect(r.offer(0, 0), isTrue);
      expect(r.offer(0.4, 3), isFalse); // < 1 s
      expect(r.offer(1, 5), isTrue);
      expect(r.offer(2, 4), isTrue); // trainer jitter → clamped to 5
      expect(r.toTrack().points.last.d, 5);
      expect(r.offer(double.nan, 6), isFalse);
      expect(r.offer(3, -1), isFalse);
      r.finish(1.5, 100); // finish never goes back in time
      expect(r.toTrack().points.last.t, 2);
      expect(r.toTrack().points.last.d, 100);
    });

    test('finish keeps the reported distance (G4 / QA Q8)', () {
      final r = AttemptRecorder()
        ..offer(0, 0)
        ..offer(1, 10)
        ..finish(2, 10); // stopped short: not stretched to the route length
      expect(r.toTrack().distanceM, 10);
      expect(ghostProblem(r.toTrack(), 5000), 'incomplete');
    });
  });

  group('delta + formatting', () {
    test('behind is +, ahead is −', () {
      final best = _steady(5); // 100 s at 500 m
      expect(ghostDeltaS(best, 500, 112), closeTo(12, 1e-9));
      expect(ghostDeltaS(best, 500, 92), closeTo(-8, 1e-9));
      expect(fmtDelta(12.4), '+0:12');
      expect(fmtDelta(-65), '−1:05');
      expect(fmtDelta(0.3), '±0:00');
    });
  });

  group('ghostProblem', () {
    test('start offset, coverage and plausibility', () {
      expect(ghostProblem(_steady(4), 1000), isNull);
      // QA: 200 s attempt that started at 4000 m of a 5000 m route.
      final late = GhostTrack([(d: 4000.0, t: 0.0), (d: 5000.0, t: 200.0)]);
      expect(ghostProblem(late, 5000), contains('starts'));
      // Within max(50 m, 1 %) of the start is fine.
      final ok = GhostTrack([(d: 40.0, t: 0.0), (d: 5000.0, t: 900.0)]);
      expect(ghostProblem(ok, 5000), isNull);
      // 1000 m in 10 s = 100 m/s.
      final fast = GhostTrack([(d: 0.0, t: 0.0), (d: 1000.0, t: 10.0)]);
      expect(ghostProblem(fast, 1000), 'implausibly fast');
    });
  });

  group('GhostStore', () {
    late Directory tmp;
    late GhostStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ghost_test');
      store = GhostStore(Directory('${tmp.path}/routes/ghosts'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('saves only complete attempts that beat the best', () {
      expect(store.load('k'), isNull);
      final half = AttemptRecorder()
        ..offer(0, 0)
        ..offer(50, 500);
      expect(store.saveIfBest('k', 'Climb', 1000, half.toTrack()), isFalse);
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      expect(store.load('k')!.totalS, closeTo(250, 0.05));
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(3)), isFalse);
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(5)), isTrue);
      expect(store.load('k')!.totalS, closeTo(200, 0.05));
      expect(store.saveIfBest('z', 'Flat', 0, _steady(5)), isFalse);
    });

    test('a partial mid-route attempt is never saved (G1)', () {
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(2)), isTrue); // 500 s
      final partial = GhostTrack([(d: 800.0, t: 0.0), (d: 1000.0, t: 40.0)]);
      expect(store.saveIfBest('k', 'Climb', 1000, partial), isFalse);
      expect(store.load('k')!.totalS, closeTo(500, 0.05));
    });

    test('Demo rides never save (G2)', () {
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(5), isDemo: true), isFalse);
      expect(store.bestFile('k').existsSync(), isFalse);
    });

    test('a bogus stored best does not block real attempts (G4 / Q9)', () {
      store.dir.createSync(recursive: true);
      store.bestFile('k').writeAsStringSync(jsonEncode({
        'v': 2, 'kind': 'ghost', 'routeKeyV2': 'k', 'routeName': 'Climb',
        'distanceM': 1000, 'totalS': 5,
        'track': {'d': [0, 20], 't': [0, 5]}, // covers 2 %
      }));
      expect(store.load('k', routeDistanceM: 1000), isNull);
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
    });

    test('load validates route key and distance (G4)', () {
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      expect(store.load('k', routeDistanceM: 1000), isNotNull);
      expect(store.load('k', routeDistanceM: 1200), isNull); // > 1 % off
      // File renamed to another key → ignored (and moved aside as foreign).
      store.bestFile('k').renameSync(store.bestFile('other').path);
      expect(store.load('other'), isNull);
    });

    test('corrupt file is moved aside, never silently overwritten (G6)', () {
      store.dir.createSync(recursive: true);
      store.bestFile('k').writeAsStringSync('{not json');
      store.now = () => DateTime.utc(2026, 10, 8);
      expect(store.load('k'), isNull);
      final aside = store.dir.listSync().whereType<File>().where(
        (f) => f.path.contains('.corrupt-'),
      );
      expect(aside, hasLength(1));
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
    });

    test('unreadable best (e.g. a directory / locked) is never overwritten (G6)', () {
      Directory(store.bestFile('k').path).createSync(recursive: true);
      expect(store.read('k'), isA<GhostUnreadable>());
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(5)), isFalse);
    });

    test('v2 file is self-describing; reset best deletes it', () {
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4), legacyKey: 'old'), isTrue);
      final m = jsonDecode(store.bestFile('k').readAsStringSync()) as Map;
      expect(m['v'], 2);
      expect(m['kind'], 'ghost');
      expect(m['routeKeyV2'], 'k');
      expect(m['routeKeyV1'], 'old');
      expect(m['sampleIntervalS'], 1);
      expect((m['rider'] as Map)['displayName'], '');
      expect(m['demo'], false);
      expect(m['createdDate'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(m.containsKey('savedAt'), isFalse); // date only, no clock time
      expect(store.resetBest('k'), isTrue);
      expect(store.load('k'), isNull);
      expect(store.resetBest('k'), isFalse);
    });

    test('an old (155eeba, v1) best is still found and migrated', () {
      final p = _profile();
      final legacy = legacyRouteKey(p);
      store.dir.createSync(recursive: true);
      store.bestFile(legacy).writeAsStringSync(jsonEncode({
        'version': 1, 'routeKey': legacy, 'routeName': p.name,
        'distanceM': p.distanceM, 'totalS': 250,
        'savedAt': '2026-10-07T21:00:00Z', 'track': _steady(4).toJson(),
      }));
      final f = store.loadForRoute(
        key: p.routeKey, legacyKey: legacy, routeName: p.name, distanceM: p.distanceM,
      );
      expect(f, isNotNull);
      expect(f!.totalS, closeTo(250, 0.05));
      expect(store.bestFile(p.routeKey).existsSync(), isTrue); // migrated
      expect(store.bestFile(legacy).existsSync(), isTrue); // old kept
    });

    test('legacy best with another name (flat-route collision) is not migrated', () {
      final p = _profile();
      final legacy = legacyRouteKey(p);
      store.dir.createSync(recursive: true);
      store.bestFile(legacy).writeAsStringSync(jsonEncode({
        'version': 1, 'routeKey': legacy, 'routeName': 'Some other flat route',
        'distanceM': p.distanceM, 'totalS': 250, 'track': _steady(4).toJson(),
      }));
      expect(
        store.loadForRoute(
          key: p.routeKey, legacyKey: legacy, routeName: p.name, distanceM: p.distanceM,
        ),
        isNull,
      );
      expect(store.bestFile(p.routeKey).existsSync(), isFalse);
    });

    test('.tdshare export → import round-trip as a friend ghost', () {
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      final share = File('${tmp.path}/out/climb.tdshare');
      expect(store.exportShare('k', share, riderName: 'Jan'), isNotNull);
      final friendStore = GhostStore(Directory('${tmp.path}/friend/ghosts'));
      final g = friendStore.importShare(share, key: 'k', routeDistanceM: 1000);
      expect(g.riderName, 'Jan');
      expect(g.totalS, closeTo(250, 0.05));
      expect(g.verified, isFalse);
      expect(File('${friendStore.dir.path}/k.friend-jan.json').existsSync(), isTrue);
      // No HR / weight / clock time in the bundle.
      final raw = utf8.decode(gzip.decode(share.readAsBytesSync()));
      expect(raw, isNot(contains('heart')));
      expect(raw, isNot(contains('savedAt')));
    });

    test('import rejects a version or route-hash mismatch', () {
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      final share = File('${tmp.path}/climb.tdshare');
      store.exportShare('k', share);
      expect(
        () => store.importShare(share, key: 'another-route', routeDistanceM: 1000),
        throwsA(isA<FormatException>().having((e) => e.message, 'msg', contains('different route'))),
      );
      expect(
        () => store.importShare(share, key: 'k', routeDistanceM: 3000),
        throwsFormatException,
      );
      final m = jsonDecode(utf8.decode(gzip.decode(share.readAsBytesSync()))) as Map;
      m['v'] = 99;
      final v99 = File('${tmp.path}/v99.tdshare')
        ..writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(m))));
      expect(
        () => store.importShare(v99, key: 'k', routeDistanceM: 1000),
        throwsA(isA<FormatException>().having((e) => e.message, 'msg', contains('version'))),
      );
      final junk = File('${tmp.path}/junk.tdshare')..writeAsStringSync('hello');
      expect(() => store.importShare(junk, key: 'k', routeDistanceM: 1000), throwsFormatException);
    });

    test('gzip bomb is stopped at the decoded cap (QA C3.2)', () {
      // 150 MB of spaces gzips to ~150 KB: under the 1 MB file limit.
      final bomb = File('${tmp.path}/bomb.tdshare');
      final sink = gzip.encoder.startChunkedConversion(
        _BytesSink((b) => bomb.writeAsBytesSync(b, mode: FileMode.append)),
      );
      final chunk = List<int>.filled(1 << 20, 0x20);
      for (var i = 0; i < 150; i++) {
        sink.add(chunk);
      }
      sink.close();
      expect(bomb.lengthSync(), lessThan(GhostStore.maxShareBytes));
      final sw = Stopwatch()..start();
      expect(
        () => store.importShare(bomb, key: 'k', routeDistanceM: 1000),
        throwsA(isA<FormatException>().having((e) => e.message, 'msg', contains('too large'))),
      );
      // Rejected early: nowhere near decoding all 150 MB.
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(
        () => GhostStore.gunzipCapped(bomb.readAsBytesSync(), 8 << 20),
        throwsA(anything),
      );
      expect(
        GhostStore.gunzipCapped(gzip.encode(utf8.encode('ok')), 16),
        utf8.encode('ok'),
      );
    });

    test('too many ghost points are rejected; friend write is atomic', () {
      final n = GhostTrack.maxPoints + 1;
      expect(
        GhostTrack.fromJson({
          'd': [for (var i = 0; i < n; i++) i * 0.02],
          't': [for (var i = 0; i < n; i++) i * 1.0],
        }),
        isNull,
      );
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      final share = File('${tmp.path}/c.tdshare');
      store.exportShare('k', share, riderName: 'Ann');
      final friend = GhostStore(Directory('${tmp.path}/f/ghosts'));
      friend.importShare(share, key: 'k', routeDistanceM: 1000);
      final names = friend.dir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, ['k.friend-ann.json'], reason: 'no .tmp left behind');
    });

    test('demo ghosts are never exported or imported (G2)', () {
      store.dir.createSync(recursive: true);
      final demo = GhostFile(
        routeKey: 'k', routeName: 'Climb', distanceM: 1000, track: _steady(4), demo: true,
      );
      store.bestFile('k').writeAsStringSync(jsonEncode(demo.toJson()));
      expect(store.exportShare('k', File('${tmp.path}/d.tdshare')), isNull);
      final forged = File('${tmp.path}/forged.tdshare')
        ..writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(demo.toJson()))));
      expect(
        () => store.importShare(forged, key: 'k', routeDistanceM: 1000),
        throwsFormatException,
      );
    });

    test('lives next to the workouts folder', () {
      final s = GhostStore.besideWorkouts('/x/Tacx Desktop/workouts');
      expect(s.dir.path.replaceAll(r'\', '/'), '/x/Tacx Desktop/routes/ghosts');
    });
  });

  group('ghost UI', () {
    test('ElevCursorPainter repaints when the ghost listenable changes', () {
      final geo = RouteGeo(_profile().samples);
      final ghost = ValueNotifier<double?>(120);
      var repaints = 0;
      final p = ElevCursorPainter(geo, ghost: ghost);
      p.addListener(() => repaints++);
      ghost.value = 130;
      expect(repaints, 1);
      expect(p.shouldRepaint(ElevCursorPainter(geo, ghost: ghost)), isFalse);
      ghost.dispose();
    });

    testWidgets('elevation chart draws progress + ghost without errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRideTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: ElevProfileChart(
                profile: _profile(),
                riderM: ValueNotifier(400),
                ghostM: ValueNotifier(450),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('elev-profile-chart')), findsOneWidget);
    });

    testWidgets('delta chip text and colour', (tester) async {
      Future<Text> chip(double d) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: GhostDeltaChip(deltaS: d)),
          ),
        );
        return tester.widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('ghost-delta-chip')),
            matching: find.byType(Text),
          ),
        );
      }

      var t = await chip(12);
      expect(t.data, '+0:12 vs best');
      expect(t.style!.color, RideColors.warn);
      t = await chip(-8);
      expect(t.data, '−0:08 vs best');
      expect(t.style!.color, RideColors.ok);
    });
  });
}

class _BytesSink implements Sink<List<int>> {
  _BytesSink(this.onData);
  final void Function(List<int>) onData;
  @override
  void add(List<int> data) => onData(data);
  @override
  void close() {}
}
