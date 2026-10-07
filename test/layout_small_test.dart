import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  for (final size in const [
    Size(1024, 768),
    Size(1280, 720),
    Size(1400, 900),
    Size(1920, 1080),
  ]) {
    testWidgets(
      'No layout overflow at ${size.width.toInt()}x${size.height.toInt()} (connected demo)',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
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
        expect(tester.takeException(), isNull);
        expect(find.text('ERG mode'), findsOneWidget);

        // Expand simulation (+ advanced if present): still no overflow.
        // Scroll the header into view first: at 1280x720 it sits below the
        // fold and a blind tap missed it (QA F3), so Simulation never opened.
        final simHeader = find.byKey(const ValueKey('simulation-header'));
        await tester.ensureVisible(simHeader);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(simHeader);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.descendant(
            of: simHeader,
            matching: find.byIcon(Icons.expand_less),
          ),
          findsOneWidget,
          reason: 'Simulation panel must actually be expanded',
        );
        final adv = find.textContaining('Advanced');
        if (adv.evaluate().isNotEmpty) {
          await tester.ensureVisible(adv.first);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tap(adv.first);
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tester.takeException(), isNull);
        // Control panels keep a usable height in every window size.
        final row = tester.getSize(find.byKey(const ValueKey('controls-row')));
        expect(row.height, greaterThanOrEqualTo(300));
        if (size.height < 800) {
          expect(
            find.byKey(const ValueKey('dashboard-scroll')),
            findsOneWidget,
          );
        }
      },
    );
  }
}
