import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Focus mode hides chrome and shows power hero', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('ERG mode'), findsOneWidget);
    expect(find.text('Simulation'), findsOneWidget);
    expect(find.byKey(const ValueKey('header-focus')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('header-focus')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('focus-ride-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-power')), findsOneWidget);
    expect(find.text('FOCUS'), findsOneWidget);
    expect(find.text('Exit Focus'), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-disconnect')), findsOneWidget);
    // Chrome hidden
    expect(find.text('ERG mode'), findsNothing);
    expect(find.text('Simulation'), findsNothing);
    expect(find.text('Find HR strap'), findsNothing);

    // Hero size token
    expect(RideType.gameHero, greaterThanOrEqualTo(72));

    await tester.tap(find.byKey(const ValueKey('focus-exit')));
    await tester.pumpAndSettle();
    expect(find.text('ERG mode'), findsOneWidget);
  });

  testWidgets('G key toggles Focus mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-ride-view')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-ride-view')), findsNothing);
  });

  test('zone wash opacity stays subtle', () {
    expect(powerGlowOpacity(0), 0);
    expect(powerGlowOpacity(150), lessThanOrEqualTo(0.12));
    expect(powerGlowOpacity(400), lessThanOrEqualTo(0.12));
    expect(powerGlowOpacity(200), greaterThanOrEqualTo(0.08));
  });
}
