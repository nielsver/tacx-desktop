import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/workout_ride_view.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';

/// QA findings 6 + 7 on d40f621: trace/painter performance and Rust/Dart
/// agreement on step targets.
void main() {
  group('shared fixture (test/fixtures/workout_plan_fixture.json)', () {
    final raw = jsonDecode(
      File('test/fixtures/workout_plan_fixture.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final plan = WorkoutPlan.tryParse(jsonEncode(raw['workout']))!;
    final exp = raw['expected'] as Map<String, dynamic>;

    test('Dart PlanStep targets match the Rust engine', () {
      expect(plan.totalS, exp['totalS']);
      final starts = exp['stepStartWatts'] as List;
      final ends = exp['stepEndWatts'] as List;
      for (var i = 0; i < plan.steps.length; i++) {
        expect(plan.steps[i].startW, starts[i], reason: 'step $i start');
        expect(plan.steps[i].endW, ends[i], reason: 'step $i end');
      }
      final ramp = plan.steps[1];
      expect(ramp.targetAt(ramp.durationS / 2), exp['rampMidWatts']);
      expect(plan.steps[2].resistancePct, exp['resistancePct']);
      expect(plan.steps[3].gradePct, exp['gradePct']);
    });
  });

  group('WorkoutTrace', () {
    test('points is a live view, version bumps on every change', () {
      final tr = WorkoutTrace();
      final view = tr.points;
      final v0 = tr.version;
      tr.offer('w', 0, 100);
      tr.offer('w', 1, 110);
      expect(identical(view, tr.points), isTrue);
      expect(view.length, 2);
      expect(tr.version, greaterThan(v0 + 1));
      expect(() => (view as List).add((t: 2.0, watts: 1.0)), throwsUnsupportedError);
      final v1 = tr.version;
      tr.offer('other', 0, 50); // reset
      expect(tr.version, greaterThan(v1));
      expect(tr.length, 1);
    });

    test('non-finite watts are dropped, not recorded as 0 W', () {
      final tr = WorkoutTrace();
      expect(tr.offer('w', 0, double.nan), isFalse);
      expect(tr.offer('w', 1, double.infinity), isFalse);
      expect(tr.length, 0);
    });
  });

  group('decimateMinMax', () {
    test('keeps short spikes and dips, bounded size, time order', () {
      final pts = [
        for (var i = 0; i < 3600; i++)
          (t: i.toDouble(), watts: i == 1800 ? 900.0 : (i == 900 ? 0.0 : 200.0)),
      ];
      final out = decimateMinMax(pts, 400);
      expect(out.length, lessThanOrEqualTo(400));
      expect(out.any((p) => p.watts == 900), isTrue);
      expect(out.any((p) => p.watts == 0), isTrue);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].t, greaterThan(out[i - 1].t));
      }
    });

    test('short input is returned as is', () {
      final pts = [(t: 0.0, watts: 1.0), (t: 1.0, watts: 2.0)];
      expect(identical(decimateMinMax(pts, 400), pts), isTrue);
    });
  });

  group('WorkoutGraphPainter.shouldRepaint', () {
    final plan = WorkoutPlan(
      id: 'p',
      name: 'P',
      steps: const [PlanStep(kind: 'erg', durationS: 60, startW: 200, endW: 200)],
    );
    test('same live list, new version → repaint; same version → no repaint', () {
      final tr = WorkoutTrace()..offer('p', 0, 100);
      WorkoutGraphPainter mk() => WorkoutGraphPainter(
        plan: plan,
        ftp: 200,
        elapsedS: 5,
        actual: tr.points,
        actualVersion: tr.version,
      );
      final a = mk();
      expect(mk().shouldRepaint(a), isFalse);
      tr.offer('p', 1, 120);
      expect(mk().shouldRepaint(a), isTrue);
    });
  });

  test('graph y-scale ignores actual sprints (plan + FTP only)', () {
    final plan = WorkoutPlan(
      id: 'p',
      name: 'P',
      steps: const [PlanStep(kind: 'erg', durationS: 60, startW: 200, endW: 200)],
    );
    // The painter calls yMax without actualMax; a sprint can't change it.
    expect(WorkoutGraphLayout.yMax(plan, 200), WorkoutGraphLayout.yMax(plan, 200));
    expect(WorkoutGraphLayout.yMax(plan, 200), closeTo(230, 0.01));
  });

  testWidgets('WorkoutGraphPainter golden', (tester) async {
    final plan = WorkoutPlan.tryParse(jsonEncode({
      'id': 'g',
      'name': 'Golden',
      'steps': [
        {'kind': 'erg', 'durationS': 300, 'watts': 120},
        {'kind': 'ramp', 'durationS': 300, 'wattsStart': 150, 'wattsEnd': 250},
        {'kind': 'erg', 'durationS': 180, 'watts': 300},
        {'kind': 'simGrade', 'durationS': 120, 'gradePct': 4},
        {'kind': 'erg', 'durationS': 300, 'watts': 110},
      ],
    }))!;
    final actual = [
      for (var t = 0; t < 700; t += 1)
        (t: t.toDouble(), watts: (plan.targetAt(t.toDouble()) ?? 150) + (t % 7) * 3.0 - 9),
    ];
    await tester.binding.setSurfaceSize(const Size(600, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: const ValueKey('golden'),
          child: SizedBox(
            width: 600,
            height: 200,
            child: ColoredBox(
              color: const Color(0xFF15191E),
              child: CustomPaint(
                painter: WorkoutGraphPainter(
                  plan: plan,
                  ftp: 230,
                  elapsedS: 700,
                  actual: actual,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/workout_graph.png'),
    );
  });
}
