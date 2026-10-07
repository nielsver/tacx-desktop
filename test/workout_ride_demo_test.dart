import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';

/// Demo end-to-end: a built-in workout started on the Demo trainer shows
/// the planned-vs-actual workout view on the dashboard and in Focus.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  Future<void> startDemoWorkout(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
      await api.connectTrainer();
      await api.startWorkout(id: id);
      // Let the engine run a couple of real seconds (1 Hz actual trace).
      await Future<void>.delayed(const Duration(milliseconds: 2300));
    });
    // Dashboard poll (250 ms) picks up the running workout.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }
  }

  Future<void> cleanUp(WidgetTester tester) async {
    await tester.runAsync(() async {
      api.stopWorkout();
      await api.disconnectTrainer();
      api.setDemoMode(enabled: false);
    });
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('demo workout shows ride view on dashboard and in Focus', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('workout-ride-view')), findsNothing);
    await startDemoWorkout(tester, 'warmup_15');

    final st = api.getWorkoutStatus();
    expect(st.running, isTrue);
    expect(find.byKey(const ValueKey('workout-ride-view')), findsOneWidget);
    expect(find.text('STEP 1/3 · ERG'), findsOneWidget);
    expect(find.text('120 W'), findsWidgets);
    expect(find.text('5:00 @ 120→150 W'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Focus (G) keeps the hero and adds the workout view, no overflow.
    await tester.tap(find.byKey(const ValueKey('header-focus')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('focus-ride-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-power')), findsOneWidget);
    expect(find.byKey(const ValueKey('workout-ride-view')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Stopping the workout removes the view.
    await tester.runAsync(() async => api.stopWorkout());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('workout-ride-view')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('focus-exit')));
    await tester.pump(const Duration(milliseconds: 300));
    await cleanUp(tester);
  });

  testWidgets('trainer disconnect mid-workout does not crash the view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await startDemoWorkout(tester, 'sweet_3x10');
    expect(find.byKey(const ValueKey('workout-ride-view')), findsOneWidget);

    await tester.runAsync(() async {
      await api.disconnectTrainer();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }
    expect(tester.takeException(), isNull);
    await cleanUp(tester);
  });
}
