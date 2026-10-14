import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';

RideStats _stats({int elapsed = 0, bool recording = false, int maxHr = 0}) =>
    RideStats(
      elapsedS: elapsed,
      movingS: elapsed,
      avgPowerW: 182.4,
      maxPowerW: 412,
      avgCadenceRpm: 88.6,
      energyKj: 135.2,
      distanceKm: 8.437,
      avgHeartRateBpm: maxHr > 0 ? 142.4 : 0,
      maxHeartRateBpm: maxHr,
      recording: recording,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  test('getRideSummary crosses FFI: nothing recorded → blanks, 4 bests', () {
    resetRideStats();
    final s = getRideSummary(ftpW: 250);
    expect(s.recordedS, 0);
    expect(s.npW, isNull);
    expect(s.tss, isNull);
    expect(s.best20MinW, isNull);
    expect(s.bestPower.map((b) => b.durationS), [5, 60, 300, 1200]);
    expect(s.bestPower.every((b) => b.watts == null), isTrue);
    expect(s.timeInZoneS, List.filled(7, 0));
    expect(getRideSummary(ftpW: 0).timeInZoneS, isEmpty);
  });

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

  testWidgets('strip shows average heart rate only when the trainer sent one', (
    tester,
  ) async {
    Widget strip(int maxHr) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1100,
          child: RideSummaryStrip(
            stats: _stats(elapsed: 60, maxHr: maxHr),
            onReset: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(strip(0));
    expect(find.byKey(const ValueKey('ride-hr')), findsNothing);
    await tester.pumpWidget(strip(171));
    expect(find.byKey(const ValueKey('ride-hr')), findsOneWidget);
    expect(find.text('142 bpm'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save TCX is disabled until something was recorded', (
    tester,
  ) async {
    var exports = 0;
    Widget strip(int elapsed) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1100,
          child: RideSummaryStrip(
            stats: _stats(elapsed: elapsed),
            onReset: () {},
            onExport: () => exports++,
          ),
        ),
      ),
    );
    await tester.pumpWidget(strip(0));
    final btn = find.byKey(const ValueKey('ride-export'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    expect(exports, 0);
    await tester.pumpWidget(strip(60));
    await tester.tap(btn);
    expect(exports, 1);
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(44));
  });

  test('default export folder is named Tacx Desktop', () {
    expect(defaultRideExportDir(), endsWith('Tacx Desktop'));
  });

  test('export with nothing recorded returns a friendly error', () async {
    resetRideStats();
    await expectLater(
      exportRideTcx(dir: Directory.systemTemp.path),
      throwsA(contains('Nothing recorded')),
    );
  });

  testWidgets('dashboard places ride summary between metrics and controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    final ride = find.byKey(const ValueKey('ride-totals'));
    expect(ride, findsOneWidget);
    final metrics = tester.getRect(find.byKey(const ValueKey('metric-power')));
    final controls = tester.getRect(find.byKey(const ValueKey('controls-row')));
    final r = tester.getRect(ride);
    expect(r.top, greaterThanOrEqualTo(metrics.bottom));
    expect(r.bottom, lessThanOrEqualTo(controls.top));
    expect(tester.takeException(), isNull);
  });
}
