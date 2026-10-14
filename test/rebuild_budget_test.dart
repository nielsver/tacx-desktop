import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

/// ~2.2 km climb: a Demo ride cannot finish it during the measured ticks.
final String _gpx = () {
  final b = StringBuffer(
    '<?xml version="1.0"?><gpx version="1.1"><trk><name>Budget Hill</name><trkseg>',
  );
  for (var i = 0; i <= 100; i++) {
    b.write(
      '<trkpt lat="${(51 + i * 0.0002).toStringAsFixed(5)}" lon="4.0">'
      '<ele>${10 + i * 0.5}</ele></trkpt>',
    );
  }
  b.write('</trkseg></trk></gpx>');
  return b.toString();
}();

/// Rebuild budget (QA C3.4 / R4–R5): during a Demo GPX ride with a ghost,
/// the dashboard must not setState per tick. Metrics, map dots, the chart
/// cursor and the ghost chip all update through notifiers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() async => RustLib.init());
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rebuild_budget');
    GhostStore.debugDirOverride = Directory('${tmp.path}/ghosts');
  });
  tearDown(() {
    GhostStore.debugDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  testWidgets('Demo GPX ride: ~0 dashboard rebuilds over 12 ticks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Seed a slow best so the ghost marker + chip are live.
    final profile = api.parseGpxXml(xml: _gpx);
    final store = GhostStore(GhostStore.debugDirOverride!);
    store.saveIfBest(
      profile.routeKey,
      profile.name,
      profile.distanceM,
      (AttemptRecorder()
            ..offer(0, 0)
            ..finish(3600, profile.distanceM))
          .toTrack(),
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': _gpx} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    Future<void> tick([int n = 1]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 260)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
      await api.connectTrainer();
    });
    await tick(3);

    final panelScroll = find.descendant(
      of: find.byKey(const ValueKey('workout-panel')),
      matching: find.byType(Scrollable),
    );
    Future<void> reveal(Finder f, {double delta = 120}) async {
      await tester.scrollUntilVisible(f, delta, scrollable: panelScroll.first);
      await tester.ensureVisible(f);
      await tester.pump();
    }

    await reveal(find.byKey(const ValueKey('gpx-paste')));
    await tester.tap(find.byKey(const ValueKey('gpx-paste')));
    await tick();
    await reveal(find.byKey(const ValueKey('gpx-start')), delta: -120);
    await tester.tap(find.byKey(const ValueKey('gpx-start')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tick(3); // settle: route start, best load, first ghost delta
    expect(api.getRouteStatus().running, isTrue);
    // Map + chart on screen (off-screen list items are not painted).
    await reveal(find.byKey(const ValueKey('route-map')));
    await tick();

    final dash0 = RideDashboard.debugBuilds;
    final metrics0 = RideDashboard.debugMetricsBuilds;
    final dots0 = RouteDotPainter.debugPaints;
    final cursor0 = ElevCursorPainter.debugPaints;
    final profile0 = ElevPainter.debugPaints;
    final line0 = RouteLinePainter.debugPaints;
    final p0 = api.getRouteStatus().progressM;

    const ticks = 12;
    await tick(ticks);

    expect(
      api.getRouteStatus().running,
      isTrue,
      reason: 'route finished early',
    );
    expect(api.getRouteStatus().progressM, greaterThan(p0));
    final dash = RideDashboard.debugBuilds - dash0;
    expect(
      dash,
      0,
      reason: 'dashboard rebuilt $dash× in $ticks route ticks (budget 0)',
    );
    expect(
      RideDashboard.debugMetricsBuilds - metrics0,
      greaterThanOrEqualTo(3),
    );
    expect(RouteDotPainter.debugPaints - dots0, greaterThanOrEqualTo(3));
    expect(ElevCursorPainter.debugPaints - cursor0, greaterThanOrEqualTo(3));
    expect(ElevPainter.debugPaints, profile0, reason: 'profile path redrawn');
    expect(RouteLinePainter.debugPaints, line0, reason: 'route line redrawn');
    expect(find.byKey(const ValueKey('ghost-delta-chip')), findsOneWidget);

    await tester.runAsync(() async {
      api.stopGpxRoute();
      await api.disconnectTrainer();
      api.setDemoMode(enabled: false);
    });
    await tick(2);
  });
}
