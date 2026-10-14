import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('QA c7 P1-B: "End ride" closes an open free ride', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    bool shown() =>
        find.byKey(const ValueKey('end-free-ride')).evaluate().isNotEmpty;
    expect(shown(), isFalse);
    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
      await api.connectTrainer();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }
    final open = api.currentEffort();
    expect(open?.kind.kind, EffortType.freeRide);
    final btn = find.byKey(const ValueKey('end-free-ride'));
    expect(shown(), isTrue);
    await tester.ensureVisible(btn);
    await tester.pump();
    await tester.tap(btn);
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.currentEffort(), isNull);
    final ended = api.getEffort(id: open!.id)!;
    expect(ended.endReason, EndReason.stopped);
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(), isFalse);
    await tester.runAsync(() async {
      await api.disconnectTrainer();
      api.setDemoMode(enabled: false);
    });
    await tester.pump(const Duration(milliseconds: 300));
  });
}
