import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// UX checklist P0-D1 (power reads first), P0-D2 (stack order) and
/// P1-D4 (connected identity in header).
Future<void> _connectDemo(WidgetTester tester) async {
  await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(() async {
    api.setDemoMode(enabled: true);
  });
  await tester.pump(const Duration(milliseconds: 300));
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
}

double _largestFont(WidgetTester tester, Finder within) {
  var max = 0.0;
  for (final e
      in find.descendant(of: within, matching: find.byType(Text)).evaluate()) {
    final size = (e.widget as Text).style?.fontSize ?? 0;
    if (size > max) max = size;
  }
  return max;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('Power is the primary metric at 1280x800', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _connectDemo(tester);
    expect(tester.takeException(), isNull);

    final power = find.byKey(const ValueKey('metric-power'));
    final others = [
      find.byKey(const ValueKey('metric-cadence')),
      find.byKey(const ValueKey('metric-speed')),
      find.byKey(const ValueKey('metric-control')),
    ];
    expect(power, findsOneWidget);
    for (final o in others) {
      expect(o, findsOneWidget);
    }

    final powerRect = tester.getRect(power);
    final powerFont = _largestFont(tester, power);
    expect(powerFont, RideType.hero);
    for (final o in others) {
      final r = tester.getRect(o);
      // Leftmost (read first in LTR), wider, and the largest value.
      expect(powerRect.left, lessThan(r.left));
      expect(powerRect.width, greaterThan(r.width * 1.5));
      expect(_largestFont(tester, o), lessThanOrEqualTo(RideType.metric));
    }
    expect(
      _largestFont(tester, find.byKey(const ValueKey('metric-control'))),
      lessThanOrEqualTo(RideType.body),
    );
  });

  testWidgets('Heart rate card appears when the trainer relays HR', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _connectDemo(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    final hr = find.byKey(const ValueKey('metric-heart rate'));
    expect(hr, findsOneWidget);
    expect(find.descendant(of: hr, matching: find.text('bpm')), findsOneWidget);
    final power = tester.getRect(find.byKey(const ValueKey('metric-power')));
    final r = tester.getRect(hr);
    expect(power.left, lessThan(r.left));
    expect(power.width, greaterThan(r.width * 1.5));
    expect(_largestFont(tester, hr), lessThanOrEqualTo(RideType.metric));
  });

  testWidgets('Stack order: metrics, then controls, then simulation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _connectDemo(tester);

    final metrics = tester.getRect(find.byKey(const ValueKey('metric-power')));
    final controls = tester.getRect(find.byKey(const ValueKey('controls-row')));
    final sim = tester.getRect(find.byKey(const ValueKey('simulation-panel')));
    expect(metrics.bottom, lessThanOrEqualTo(controls.top));
    expect(controls.bottom, lessThanOrEqualTo(sim.top));
  });

  for (final width in const [1024.0, 1280.0]) {
    testWidgets('Header shows trainer name and protocol when connected '
        '(${width.toInt()} wide)', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _connectDemo(tester);
      expect(tester.takeException(), isNull);
      final id = find.byKey(const ValueKey('header-identity'));
      expect(id, findsOneWidget);
      final text = (tester.widget<Text>(id)).data!;
      expect(text, contains(' · '));
      expect(text.split(' · ').first.trim(), isNotEmpty);
    });
  }
}
