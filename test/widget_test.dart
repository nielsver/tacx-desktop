import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Ride dashboard loads in demo mode', (tester) async {
    // Desktop-sized surface (default 800x600 overflows the control panels).
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Tacx Desktop'), findsOneWidget);
    expect(find.text('DEMO'), findsOneWidget);
    expect(find.text('ERG mode'), findsOneWidget);
    expect(find.text('Resistance'), findsOneWidget);
    expect(find.text('Intervals'), findsOneWidget);
    expect(find.text('Simulation'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    for (final w in [100, 150, 200, 250]) {
      expect(find.byKey(ValueKey('erg-preset-$w')), findsOneWidget);
    }
  });
  testWidgets('ERG preset shows sent confirmation snackbar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));

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

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('erg-preset-200')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ERG target 200 W sent'), findsOneWidget);
  });
}
