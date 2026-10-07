import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// P0-X4: every interactive control is >= kMinTapTarget tall on all three
/// desktop platforms (Flutter would otherwise apply compact density there).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  bool isTappable(Widget w) =>
      w is ButtonStyleButton ||
      w is ActionChip ||
      w is Switch ||
      w is SegmentedButton ||
      (w is InkWell && w.key == const ValueKey('simulation-header'));

  void expectTargets(WidgetTester tester, String phase) {
    final found = find.byWidgetPredicate(isTappable);
    expect(found, findsWidgets);
    for (final e in found.evaluate()) {
      final box = e.renderObject;
      if (box is! RenderBox || !box.hasSize) continue;
      expect(
        box.size.height,
        greaterThanOrEqualTo(kMinTapTarget),
        reason:
            '$phase: ${e.widget.runtimeType} '
            '${e.widget.key ?? ''} is ${box.size.height}px tall',
      );
    }
  }

  testWidgets(
    'Tap targets >= 44px (scan, connected, simulation open)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const TacxDesktopApp());
      await tester.pump(const Duration(milliseconds: 100));
      expectTargets(tester, 'idle');

      await tester.runAsync(() async {
        await tester.tap(find.text('Scan'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expectTargets(tester, 'scanned');

      await tester.runAsync(() async {
        await tester.tap(find.text('Connect'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expectTargets(tester, 'connected');

      await tester.tap(find.byKey(const ValueKey('simulation-header')));
      await tester.pump(const Duration(milliseconds: 200));
      final adv = find.textContaining('Advanced');
      if (adv.evaluate().isNotEmpty) {
        await tester.ensureVisible(adv.first);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(adv.first);
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tester.takeException(), isNull);
      expectTargets(tester, 'simulation');
    },
    variant: TargetPlatformVariant.desktop(),
  );
}
