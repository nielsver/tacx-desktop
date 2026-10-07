import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';

/// Every visible Text that shows a live number (digits) at metric size or
/// bigger must use tabular figures (step 3, DT2).
List<String> _proportionalNumbers(WidgetTester tester) {
  final bad = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final rt = e.widget as RichText;
    final text = rt.text.toPlainText();
    if (!RegExp(r'\d').hasMatch(text)) continue;
    final style = (rt.text as TextSpan).style;
    final size = style?.fontSize ?? 14;
    if (size < RideType.metric) continue;
    final ff = style?.fontFeatures ?? const [];
    if (!ff.contains(const FontFeature.tabularFigures())) {
      bad.add('"$text" @${size.toStringAsFixed(0)}');
    }
  }
  return bad;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  group('AppTokens', () {
    test('registered in the ride theme', () {
      final t = buildRideTheme().extension<AppTokens>();
      expect(t, isNotNull);
      expect(t!.space, [4, 8, 12, 16, 24]);
      expect(t.zones, kZoneColors);
    });

    test('lerp endpoints and copyWith', () {
      const a = AppTokens();
      final b = a.copyWith(rMd: 20, space: const [2, 4, 6, 8, 10]);
      expect(a.lerp(b, 0).rMd, a.rMd);
      expect(a.lerp(b, 1).rMd, 20);
      expect(a.lerp(b, 1).space, [2, 4, 6, 8, 10]);
      expect(a.lerp(b, 0.5).rMd, 16);
      expect(a.lerp(null, 0.5).rMd, a.rMd);
    });

    test('zoneFor uses the Coggan bands', () {
      const t = AppTokens();
      expect(t.zoneFor(100, 200), kZoneColors[0]); // 50 % → Z1
      expect(t.zoneFor(200, 200), kZoneColors[3]); // 100 % → Z4
      expect(t.zoneFor(400, 200), kZoneColors[6]); // 200 % → Z7
    });
  });

  testWidgets('live numbers use tabular figures (dashboard + Focus)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
      await api.connectTrainer();
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }
    expect(_proportionalNumbers(tester), isEmpty, reason: 'dashboard');

    await tester.tap(find.byKey(const ValueKey('header-focus')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }
    expect(find.byKey(const ValueKey('focus-ride-view')), findsOneWidget);
    expect(_proportionalNumbers(tester), isEmpty, reason: 'focus');

    await tester.runAsync(() async {
      await api.disconnectTrainer();
      api.setDemoMode(enabled: false);
    });
    await tester.pump(const Duration(milliseconds: 300));
  });
}
