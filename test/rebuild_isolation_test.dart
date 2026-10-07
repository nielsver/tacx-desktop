import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  // P0-P2: live power/cadence ticks during a steady ride must only rebuild
  // the metric cards, not the header / connection bar / control panels.
  testWidgets('steady demo ride rebuilds metrics, not the whole dashboard', (
    tester,
  ) async {
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
    // Let connect settle (snapshot / mode transitions).
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 260)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }

    final dash0 = RideDashboard.debugBuilds;
    final metrics0 = RideDashboard.debugMetricsBuilds;
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 260)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    final dashDelta = RideDashboard.debugBuilds - dash0;
    final metricsDelta = RideDashboard.debugMetricsBuilds - metrics0;

    expect(
      metricsDelta,
      greaterThanOrEqualTo(3),
      reason: 'demo metrics should tick the metric cards',
    );
    expect(
      dashDelta,
      lessThanOrEqualTo(1),
      reason: 'whole dashboard rebuilt $dashDelta× for $metricsDelta ticks',
    );
  });
}
