import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';

Future<void> _enableDemo(WidgetTester tester) async {
  await tester.runAsync(() async {
    api.setDemoMode(enabled: true);
  });
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Ride dashboard loads with Demo OFF by default', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Tacx Desktop'), findsOneWidget);
    expect(find.text('DEMO'), findsNothing);
    expect(find.byKey(const ValueKey('demo-switch')), findsOneWidget);
    expect(find.text('ERG mode'), findsOneWidget);
    expect(find.text('Resistance'), findsOneWidget);
    expect(find.text('Workouts'), findsOneWidget);
    expect(find.text('Simulation'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    for (final w in [100, 150, 200, 250]) {
      expect(find.byKey(ValueKey('erg-preset-$w')), findsOneWidget);
    }
  });

  testWidgets('Demo switch toggles stub devices on and off', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('DEMO'), findsNothing);
    final sw = find.byKey(const ValueKey('demo-switch'));
    expect(tester.widget<Switch>(sw).value, isFalse);

    await tester.tap(sw);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Switch>(sw).value, isTrue);
    expect(find.text('DEMO'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Scan'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Demo trainers'), findsOneWidget);
    expect(find.textContaining('DEMO Tacx Neo'), findsWidgets);

    await tester.tap(sw);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Switch>(sw).value, isFalse);
    expect(find.text('DEMO'), findsNothing);
    expect(find.textContaining('DEMO Tacx Neo'), findsNothing);
    expect(find.textContaining('Demo trainers'), findsNothing);
  });

  testWidgets('ERG preset shows sent confirmation snackbar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await _enableDemo(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Scan'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(find.text('Connect'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));

    final preset = find.byKey(const ValueKey('erg-preset-200'));
    await tester.ensureVisible(preset);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(preset);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('ERG 200 W sent'), findsOneWidget);
    expect(find.textContaining('3–5 s'), findsWidgets);
  });

  testWidgets('Resistance auto-applies once on slider release', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await _enableDemo(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Scan'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(find.text('Connect'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('resistance-auto-apply')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.drag(
        find.byKey(const ValueKey('resistance-slider')),
        const Offset(60, 0),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('% sent'), findsOneWidget);
  });
}
