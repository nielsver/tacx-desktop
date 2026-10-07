import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

GpxProfileInfo _profile({String name = 'Climb', double bump = 0}) =>
    GpxProfileInfo(
      name: name,
      distanceM: 1000,
      elevGainM: 50,
      samples: [
        for (var i = 0; i <= 10; i++)
          ElevSample(
            distanceM: i * 100.0,
            elevM: 100 + i * 5.0 + (i == 5 ? bump : 0),
            gradePct: 5,
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
  group('routeKey', () {
    test('stable for the same profile, ignores the track name', () {
      expect(routeKey(_profile()), routeKey(_profile(name: 'Other name')));
      expect(routeKey(_profile()).length, 16);
    });
    test('changes when the elevation profile changes', () {
      expect(routeKey(_profile()), isNot(routeKey(_profile(bump: 3))));
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

  group('GhostStore', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ghost_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('saves only complete attempts that beat the best', () {
      final store = GhostStore(Directory('${tmp.path}/routes/ghosts'));
      expect(store.load('k'), isNull);
      // Incomplete (stopped half-way) → not saved.
      final half = AttemptRecorder()
        ..offer(0, 0)
        ..offer(50, 500);
      expect(store.saveIfBest('k', 'Climb', 1000, half.toTrack()), isFalse);
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      expect(store.load('k')!.totalS, closeTo(250, 0.05));
      // Slower → kept old best.
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(3)), isFalse);
      // Faster → replaces.
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(5)), isTrue);
      expect(store.load('k')!.totalS, closeTo(200, 0.05));
      // Zero-distance route never saves.
      expect(store.saveIfBest('z', 'Flat', 0, _steady(5)), isFalse);
    });

    test('corrupt file is ignored and then overwritten', () {
      final dir = Directory('${tmp.path}/g')..createSync();
      File('${dir.path}/k.best.json').writeAsStringSync('{not json');
      final store = GhostStore(dir);
      expect(store.load('k'), isNull);
      expect(store.saveIfBest('k', 'Climb', 1000, _steady(4)), isTrue);
      expect(store.load('k'), isNotNull);
    });

    test('lives next to the workouts folder', () {
      final s = GhostStore.besideWorkouts('/x/Tacx Desktop/workouts');
      expect(s.dir.path.replaceAll(r'\', '/'), '/x/Tacx Desktop/routes/ghosts');
    });
  });

  group('ghost UI', () {
    test('ElevPainter repaints when the ghost moves', () {
      final s = _profile().samples;
      final a = ElevPainter(s, progressM: 100, ghostM: 120);
      expect(
        a.shouldRepaint(ElevPainter(s, progressM: 100, ghostM: 120)),
        isFalse,
      );
      expect(
        a.shouldRepaint(ElevPainter(s, progressM: 100, ghostM: 130)),
        isTrue,
      );
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
                progressM: 400,
                ghostM: 450,
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
