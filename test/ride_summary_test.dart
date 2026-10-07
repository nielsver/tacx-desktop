import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';

RideStats _stats({int elapsed = 0, bool recording = false}) => RideStats(
  elapsedS: elapsed,
  movingS: elapsed,
  avgPowerW: 182.4,
  maxPowerW: 412,
  avgCadenceRpm: 88.6,
  energyKj: 135.2,
  distanceKm: 8.437,
  recording: recording,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  test('ride clock formats mm:ss and h:mm:ss', () {
    expect(RideSummaryStrip.clock(0), '00:00');
    expect(RideSummaryStrip.clock(754), '12:34');
    expect(RideSummaryStrip.clock(3725), '1:02:05');
  });

  testWidgets('strip shows totals and Reset fires', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            child: RideSummaryStrip(
              stats: _stats(elapsed: 754, recording: true),
              onReset: () => resets++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('12:34'), findsOneWidget);
    expect(find.text('182 W'), findsOneWidget);
    expect(find.text('412 W'), findsOneWidget);
    expect(find.text('89 rpm'), findsOneWidget);
    expect(find.text('135 kJ'), findsOneWidget);
    expect(find.text('8.44 km'), findsOneWidget);
    expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ride-reset')));
    expect(resets, 1);
  });

  testWidgets('dashboard places ride summary between metrics and controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));
    final ride = find.byKey(const ValueKey('ride-summary'));
    expect(ride, findsOneWidget);
    final metrics = tester.getRect(find.byKey(const ValueKey('metric-power')));
    final controls = tester.getRect(find.byKey(const ValueKey('controls-row')));
    final r = tester.getRect(ride);
    expect(r.top, greaterThanOrEqualTo(metrics.bottom));
    expect(r.bottom, lessThanOrEqualTo(controls.top));
    expect(tester.takeException(), isNull);
  });
}
