import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/workout_ride_view.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';

/// warm-up style plan: 300 s @ 120 W, ramp 300 s 120→150 W, 600 s @ 250 W,
/// 120 s sim grade 4 %.
WorkoutPlan _plan() => WorkoutPlan.tryParse('''
{"version":1,"id":"t1","name":"Test plan","steps":[
 {"kind":"erg","durationS":300,"watts":120},
 {"kind":"ramp","durationS":300,"wattsStart":120,"wattsEnd":150},
 {"kind":"erg","durationS":600,"watts":250},
 {"kind":"simGrade","durationS":120,"gradePct":4.0}
]}''')!;

Widget _host(Widget child, {Size size = const Size(1100, 220)}) => MaterialApp(
  theme: buildRideTheme(),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: size.width, height: size.height, child: child),
    ),
  ),
);

void main() {
  group('WorkoutPlan', () {
    test('parses steps and cumulative time axis', () {
      final p = _plan();
      expect(p.steps.length, 4);
      expect(p.totalS, 1320);
      expect(p.startOf(0), 0);
      expect(p.startOf(2), 600);
      expect(p.startOf(4), 1320);
      expect(p.maxWatts, 250);
      expect(p.stepIndexAt(0), 0);
      expect(p.stepIndexAt(299.9), 0);
      expect(p.stepIndexAt(300), 1);
      expect(p.stepIndexAt(5000), 3);
      expect(p.targetAt(450), closeTo(135, 0.001)); // mid-ramp
      expect(p.targetAt(1300), isNull); // sim step has no watts
    });

    test('elapsed from engine status (step index + time left)', () {
      final p = _plan();
      expect(p.elapsedFrom(stepIndex: 0, remainingS: 300), 0);
      expect(p.elapsedFrom(stepIndex: 2, remainingS: 100), 1100);
      // Out-of-range values are clamped, never negative / past the end.
      expect(p.elapsedFrom(stepIndex: 9, remainingS: -5), 1320);
      expect(p.elapsedFrom(stepIndex: 1, remainingS: 999), 300);
      expect(p.elapsedFrom(stepIndex: 0, remainingS: 0, done: true), 1320);
    });

    test('zero-length / missing durations become 1 s like the engine', () {
      final p = WorkoutPlan.tryParse(
        '{"id":"z","name":"z","steps":[{"kind":"erg","durationS":0,"watts":100},'
        '{"kind":"erg","watts":200}]}',
      )!;
      expect(p.steps.map((s) => s.durationS), [1, 1]);
      expect(p.totalS, 2);
    });

    test('invalid JSON → null, empty plan is safe', () {
      expect(WorkoutPlan.tryParse('not json'), isNull);
      expect(WorkoutPlan.tryParse('[]'), isNull);
      final empty = WorkoutPlan.tryParse('{"id":"e","name":"e","steps":[]}')!;
      expect(empty.totalS, 0);
      expect(empty.targetAt(10), isNull);
      expect(empty.elapsedFrom(stepIndex: 0, remainingS: 0), 0);
      expect(
        WorkoutGraphLayout.blocks(empty, const Size(100, 50), 200),
        isEmpty,
      );
    });
  });

  group('zones', () {
    test('Coggan bands from FTP', () {
      expect(powerZone(100, 200), 1); // 50 %
      expect(powerZone(140, 200), 2); // 70 %
      expect(powerZone(170, 200), 3); // 85 %
      expect(powerZone(200, 200), 4); // 100 %
      expect(powerZone(230, 200), 5); // 115 %
      expect(powerZone(280, 200), 6); // 140 %
      expect(powerZone(400, 200), 7); // 200 %
      expect(powerZone(100, 0), 7); // FTP 0 never divides by zero
    });
  });

  group('WorkoutGraphLayout.blocks', () {
    const size = Size(1320, 200);

    test('width ∝ duration and blocks tile the full width', () {
      final p = _plan();
      final b = WorkoutGraphLayout.blocks(p, size, 200, yMaxW: 400);
      expect(b.length, 4);
      expect(b[0].x0, 0);
      expect(b[0].width, closeTo(300, 1e-9));
      expect(b[1].width, closeTo(300, 1e-9));
      expect(b[2].width, closeTo(600, 1e-9));
      expect(b[3].x1, closeTo(size.width, 1e-9));
      for (var i = 1; i < b.length; i++) {
        expect(b[i].x0, closeTo(b[i - 1].x1, 1e-9));
      }
    });

    test('height ∝ target watts, ramps slope, zone colours from FTP', () {
      final p = _plan();
      final b = WorkoutGraphLayout.blocks(p, size, 200, yMaxW: 400);
      // 120 W of 400 → 30 % of the height from the bottom.
      expect(b[0].yTop0, closeTo(200 * (1 - 120 / 400), 1e-9));
      expect(b[0].yTop0, b[0].yTop1);
      expect(b[1].yTop0, closeTo(200 * (1 - 120 / 400), 1e-9));
      expect(b[1].yTop1, closeTo(200 * (1 - 150 / 400), 1e-9));
      expect(b[2].yTop0, closeTo(200 * (1 - 250 / 400), 1e-9));
      expect(b[0].color, zoneColor(2)); // 120/200 = 60 % → Z2
      expect(b[2].color, zoneColor(6)); // 250/200 = 125 % → Z6
    });

    test('non-power steps get a neutral block', () {
      final b = WorkoutGraphLayout.blocks(_plan(), size, 200, yMaxW: 400);
      expect(b[3].color, kNonPowerStepColor);
      expect(b[3].yTop0, lessThan(size.height));
      expect(b[3].yTop0, greaterThan(0));
    });

    test('yMax leaves headroom over plan and FTP, caps spikes', () {
      final p = _plan();
      expect(WorkoutGraphLayout.yMax(p, 200), closeTo(250 * 1.15, 1e-9));
      expect(WorkoutGraphLayout.yMax(p, 300), closeTo(300 * 1.15, 1e-9));
      // A 2000 W sprint spike cannot flatten the plan: cap at 1.6 × base.
      expect(
        WorkoutGraphLayout.yMax(p, 200, actualMax: 2000),
        closeTo(250 * 1.6 * 1.15, 1e-9),
      );
    });
  });

  group('3-2-1 countdown timing', () {
    test('shows 3, 2, 1 in the last three seconds when a step follows', () {
      int? cd(double r) => stepCountdown(r, hasNext: true);
      expect(cd(10), isNull);
      expect(cd(3.01), isNull);
      expect(cd(3.0), 3);
      expect(cd(2.6), 3);
      expect(cd(2.0), 2);
      expect(cd(1.4), 2);
      expect(cd(1.0), 1);
      expect(cd(0.2), 1);
      expect(cd(0), isNull);
      expect(cd(-1), isNull);
      expect(cd(double.nan), isNull);
    });

    test('no countdown on the last step', () {
      expect(stepCountdown(2, hasNext: false), isNull);
    });
  });

  group('WorkoutTrace', () {
    test('1 Hz points, resets on new workout or restart', () {
      final t = WorkoutTrace();
      expect(t.offer('a', 0, 100), isTrue);
      expect(t.offer('a', 0.25, 110), isFalse); // < 1 s apart
      expect(t.offer('a', 1.0, 120), isTrue);
      // Non-finite samples are dropped (no fake 0 W dips, QA finding 2).
      expect(t.offer('a', 2.0, double.nan), isFalse);
      expect(t.offer('a', 2.0, -5), isTrue);
      expect(t.points.last.watts, 0);
      expect(t.length, 3);
      // Same workout restarted: time jumps back → new trace.
      t.offer('a', 0, 90);
      expect(t.length, 1);
      // Different workout → new trace.
      t.offer('b', 5, 90);
      expect(t.workoutId, 'b');
      expect(t.length, 1);
      t.clear();
      expect(t.length, 0);
    });
  });

  group('IntervalTimeline widget', () {
    testWidgets('current target, time left and next step', (tester) async {
      await tester.pumpWidget(
        _host(
          IntervalTimeline(
            plan: _plan(),
            progress: const WorkoutProgress(stepIndex: 2, remainingS: 125),
            ftp: 200,
            elapsedS: 600 + 475,
          ),
          size: const Size(1100, 90),
        ),
      );
      expect(find.text('250 W'), findsOneWidget);
      expect(find.text('STEP 3/4 · ERG'), findsOneWidget);
      expect(find.text('2:05'), findsOneWidget);
      expect(find.text('2:00 @ 4.0 %'), findsOneWidget);
      expect(find.byKey(const ValueKey('workout-countdown-3')), findsNothing);
    });

    testWidgets('3-2-1 badge before the step change', (tester) async {
      for (final (rem, shown) in [(2.5, 3), (1.5, 2), (0.4, 1)]) {
        await tester.pumpWidget(
          _host(
            IntervalTimeline(
              plan: _plan(),
              progress: WorkoutProgress(stepIndex: 0, remainingS: rem),
              ftp: 200,
              elapsedS: 300 - rem,
            ),
            size: const Size(1100, 90),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.byKey(ValueKey('workout-countdown-$shown')),
          findsOneWidget,
          reason: 'remaining $rem s',
        );
      }
    });

    testWidgets('last step says Finish and never counts down', (tester) async {
      await tester.pumpWidget(
        _host(
          IntervalTimeline(
            plan: _plan(),
            progress: const WorkoutProgress(stepIndex: 3, remainingS: 2),
            ftp: 200,
            elapsedS: 1318,
          ),
          size: const Size(1100, 90),
        ),
      );
      expect(find.text('Finish'), findsOneWidget);
      expect(find.textContaining('workout-countdown'), findsNothing);
      expect(find.byKey(const ValueKey('workout-countdown-2')), findsNothing);
    });
  });

  group('WorkoutRideView', () {
    for (final size in const [
      Size(900, 200),
      Size(1366, 320),
      Size(600, 190),
    ]) {
      testWidgets('renders without overflow at $size', (tester) async {
        final trace = WorkoutTrace();
        for (var s = 0; s < 400; s += 1) {
          trace.offer('t1', s.toDouble(), 110 + (s % 40).toDouble());
        }
        await tester.pumpWidget(
          _host(
            WorkoutRideView(
              plan: _plan(),
              progress: const WorkoutProgress(stepIndex: 1, remainingS: 200),
              trace: trace,
              ftp: 200,
              large: size.height > 300,
              onEditFtp: () {},
            ),
            size: size,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('workout-graph')), findsOneWidget);
        expect(find.text('FTP 200 W'), findsOneWidget);
      });
    }

    testWidgets('done state shows the workout name and full clock', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          WorkoutRideView(
            plan: _plan(),
            progress: const WorkoutProgress(
              stepIndex: 3,
              remainingS: 0,
              running: false,
              done: true,
            ),
            trace: WorkoutTrace(),
            ftp: 200,
          ),
        ),
      );
      expect(find.text('WORKOUT DONE'), findsOneWidget);
      expect(find.text('22:00 / 22:00'), findsOneWidget);
    });
  });
}
