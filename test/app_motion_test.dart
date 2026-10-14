import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/workout_ride_view.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';

/// Step 3 subtle motion: AppMotion tokens + reduced-motion behaviour.
void main() {
  final plan = WorkoutPlan(
    id: 'm',
    name: 'M',
    steps: const [
      PlanStep(kind: 'erg', durationS: 60, startW: 150, endW: 150),
      PlanStep(kind: 'erg', durationS: 60, startW: 300, endW: 300),
    ],
  );

  Widget host(int step, {required bool reduce}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Scaffold(
        body: SizedBox(
          width: 900,
          child: IntervalTimeline(
            plan: plan,
            progress: WorkoutProgress(stepIndex: step, remainingS: 60),
            ftp: 250,
            elapsedS: step * 60.0 + 1,
          ),
        ),
      ),
    ),
  );

  String target(WidgetTester t) => t
      .widget<Text>(find.byKey(const ValueKey('workout-current-target')))
      .data!;

  double pulseAlpha(WidgetTester t) =>
      (t
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('interval-pulse')),
                  )
                  .decoration
              as BoxDecoration)
          .color!
          .a;

  test('tokens: reduced set is all zero', () {
    expect(AppMotion.normal.enabled, isTrue);
    expect(AppMotion.reduced.enabled, isFalse);
    expect(AppMotion.reduced.medium, Duration.zero);
    expect(AppMotion.reduced.pulse, Duration.zero);
  });

  testWidgets('animations on: target eases and interval pulses', (t) async {
    await t.pumpWidget(host(0, reduce: false));
    expect(target(t), '150 W');
    await t.pumpWidget(host(1, reduce: false));
    await t.pump(const Duration(milliseconds: 100));
    final mid = int.parse(target(t).split(' ').first);
    expect(mid, inExclusiveRange(150, 300));
    expect(pulseAlpha(t), greaterThan(0));
    await t.pumpAndSettle();
    expect(target(t), '300 W');
    expect(pulseAlpha(t), 0);
  });

  testWidgets('animations disabled: target snaps, no pulse', (t) async {
    await t.pumpWidget(host(0, reduce: true));
    await t.pumpWidget(host(1, reduce: true));
    await t.pump();
    expect(target(t), '300 W');
    expect(pulseAlpha(t), 0);
    expect(t.hasRunningAnimations, isFalse);
  });
}
