import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.setDemoMode(enabled: false);
  });

  testWidgets('Cold start shows Welcome with mode cards and CTAs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('welcome-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-card-erg')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-card-demo')), findsOneWidget);
    expect(find.byKey(const ValueKey('welcome-connect')), findsOneWidget);
    expect(find.byKey(const ValueKey('welcome-try-demo')), findsOneWidget);
    expect(find.text('ERG mode'), findsNothing);
  });

  testWidgets('Connect trainer → Connect page; Start gated until Demo', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('welcome-connect')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('connect-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('bluetooth-tips')), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-gate-reason')), findsOneWidget);

    final start = find.byKey(const ValueKey('connect-start-ride'));
    expect(tester.widget<FilledButton>(start).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('connect-use-demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connect-demo-banner')), findsOneWidget);
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);

    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(find.text('ERG mode'), findsOneWidget);
    expect(find.text('DEMO'), findsOneWidget);

    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('ride.welcomeSeen'), isTrue);
      expect(prefs.getBool('ride.demoMode'), isTrue);
    });
  });

  testWidgets('Try Demo from Welcome enables Start and DEMO chip', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('welcome-try-demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connect-demo-banner')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('connect-start-ride')));
    await tester.pumpAndSettle();
    expect(find.text('DEMO'), findsOneWidget);
  });

  testWidgets('Returning user with welcomeSeen skips Welcome', (tester) async {
    SharedPreferences.setMockInitialValues({'ride.welcomeSeen': true});
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('welcome-page')), findsNothing);
    expect(find.byKey(const ValueKey('connect-page')), findsOneWidget);
  });

  testWidgets('Focus gated off ride until Demo or connected', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    api.setDemoMode(enabled: false);
    await tester.pump(const Duration(milliseconds: 300));

    final focus = find.byKey(const ValueKey('header-focus'));
    expect(focus, findsOneWidget);
    // Disabled TextButton has onPressed null
    final btn = tester.widget<TextButton>(focus);
    expect(btn.onPressed, isNull);

    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TextButton>(focus).onPressed, isNotNull);
  });
}
