import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart';
import 'package:tacx_desktop/src/ui/live_trend_chart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  test('listWorkouts includes built-in pack', () {
    final list = api.listWorkouts();
    final ids = list.map((w) => w.id).toSet();
    expect(ids.contains('warmup_15'), isTrue);
    expect(ids.contains('sweet_3x10'), isTrue);
    expect(ids.contains('vo2_5x3'), isTrue);
    expect(ids.contains('recovery_30'), isTrue);
    expect(ids.contains('hilly_sim_20'), isTrue);
    expect(ids.contains('10x30_30'), isTrue);
    expect(list.length, greaterThanOrEqualTo(7));
  });

  test('parseGpxXml builds elevation profile', () {
    const xml = '''<?xml version="1.0"?>
<gpx version="1.1"><trk><name>Unit Climb</name><trkseg>
<trkpt lat="50.0" lon="4.0"><ele>100</ele></trkpt>
<trkpt lat="50.001" lon="4.0"><ele>110</ele></trkpt>
<trkpt lat="50.002" lon="4.0"><ele>125</ele></trkpt>
</trkseg></trk></gpx>''';
    final p = api.parseGpxXml(xml: xml);
    expect(p.name, 'Unit Climb');
    expect(p.distanceM, greaterThan(100));
    expect(p.elevGainM, greaterThan(20));
    expect(p.samples.length, greaterThanOrEqualTo(2));
  });

  test('workout JSON round-trip via save path for custom', () {
    final json =
        '{"version":1,"id":"test_custom_ui","name":"UI Test","description":"","builtin":false,'
        '"steps":[{"kind":"erg","durationS":60,"watts":180}]}';
    // May write under Documents — fine in CI.
    final path = api.saveWorkoutJson(json: json);
    expect(path.contains('workouts'), isTrue);
    final loaded = api.loadWorkoutJson(id: 'test_custom_ui');
    expect(loaded.contains('180'), isTrue);
  });

  testWidgets('dashboard shows Workouts panel in demo', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('workout-panel')), findsOneWidget);
    // Library is loaded from Rust; at least one built-in label appears.
    expect(
      find.textContaining('warm-up').evaluate().isNotEmpty ||
          find.textContaining('Workouts').evaluate().isNotEmpty,
      isTrue,
    );
  });

  test('TrendPainter accepts ERG target', () {
    final samples = [
      const TrendSample(powerW: 100, cadenceRpm: 80),
      const TrendSample(powerW: 200, cadenceRpm: 90),
    ];
    final p = TrendPainter(samples, capacity: 600, targetWatts: 180);
    expect(p.targetWatts, 180);
  });

  test('ElevPainter builds from samples', () {
    final samples = [
      const ElevSample(distanceM: 0, elevM: 100, gradePct: 0, lat: 50, lon: 4),
      const ElevSample(distanceM: 100, elevM: 110, gradePct: 5, lat: 50.001, lon: 4),
    ];
    final painter = ElevPainter(samples, progressM: 40);
    expect(painter.progressM, 40);
  });
}
