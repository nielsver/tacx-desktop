import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/ride_prefs.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  test('RidePrefs round-trips through shared_preferences', () async {
    SharedPreferences.setMockInitialValues({});
    const p = RidePrefs(
      focusMode: true,
      focusEffectsSubtle: true,
      targetWatts: 235,
      ergStep: 25,
      userWeightKg: 82,
      resAutoApply: false,
    );
    expect(await p.save(), isTrue);
    final back = await RidePrefs.load();
    expect(back, isNotNull);
    expect(back!.focusMode, isTrue);
    expect(back.focusEffectsSubtle, isTrue);
    expect(back.targetWatts, 235);
    expect(back.ergStep, 25);
    expect(back.userWeightKg, 82);
    expect(back.resAutoApply, isFalse);
  });

  test('RidePrefs sanitizes stale or hand-edited values', () async {
    SharedPreferences.setMockInitialValues({
      'ride.ergTargetW': 99999,
      'ride.ergStepW': 7,
      'ride.userWeightKg': 500.0,
    });
    final p = (await RidePrefs.load())!;
    expect(p.targetWatts, 2000);
    expect(p.ergStep, 10);
    expect(p.userWeightKg, 120);
  });

  testWidgets('Dashboard restores Focus mode and persists exit', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ride.focusMode': true,
      'ride.ergTargetW': 230,
    });
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('focus-ride-view')), findsOneWidget);
    expect(find.textContaining('230'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('focus-exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-ride-view')), findsNothing);

    // Debounced write lands.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('ride.focusMode'), isFalse);
      expect(prefs.getInt('ride.ergTargetW'), 230);
    });
  });
}
