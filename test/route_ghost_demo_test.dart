import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';

/// ~45 m route so a Demo ride finishes in a few real seconds.
const _gpx = '''<?xml version="1.0"?>
<gpx version="1.1"><trk><name>Ghost Test Hill</name><trkseg>
<trkpt lat="51.00000" lon="4.0"><ele>10</ele></trkpt>
<trkpt lat="51.00020" lon="4.0"><ele>11</ele></trkpt>
<trkpt lat="51.00040" lon="4.0"><ele>12.5</ele></trkpt>
</trkseg></trk></gpx>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Demo GPX ride shows ghost chip and stores a new best', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final profile = api.parseGpxXml(xml: _gpx);
    final key = routeKey(profile);
    final store = GhostStore.besideWorkouts(api.workoutsDir());
    final file = File('${store.dir.path}/$key.best.json');
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    // Seed a slow previous best (10 minutes) so the ghost is behind us.
    if (file.existsSync()) file.deleteSync();
    final slow = AttemptRecorder()
      ..offer(0, 0)
      ..finish(600, profile.distanceM);
    expect(
      store.saveIfBest(key, profile.name, profile.distanceM, slow.toTrack()),
      isTrue,
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': _gpx};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(const TacxDesktopApp(skipOnboarding: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      api.setDemoMode(enabled: true);
      await api.connectTrainer();
    });
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }

    final panelScroll = find.descendant(
      of: find.byKey(const ValueKey('workout-panel')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gpx-paste')),
      120,
      scrollable: panelScroll.first,
    );
    await tester.tap(find.byKey(const ValueKey('gpx-paste')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('route-best')),
      120,
      scrollable: panelScroll.first,
    );
    expect(find.textContaining('Best 10:00'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gpx-start')),
      -120,
      scrollable: panelScroll.first,
    );
    await tester.tap(find.byKey(const ValueKey('gpx-start')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1600)),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 260));
    }
    expect(api.getRouteStatus().running, isTrue);
    expect(find.byKey(const ValueKey('ghost-delta-chip')), findsOneWidget);
    expect(find.textContaining('vs best'), findsOneWidget);
    // Way ahead of a 10-minute ghost.
    expect(find.textContaining('−'), findsWidgets);

    // Ride to the finish (Demo ≥ 5 m/s over ~45 m).
    for (var i = 0; i < 40 && !api.getRouteStatus().complete; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 260));
    }
    await tester.pump(const Duration(milliseconds: 260));
    expect(api.getRouteStatus().complete, isTrue);
    expect(find.byKey(const ValueKey('ghost-delta-chip')), findsNothing);

    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect((saved['totalS'] as num).toDouble(), lessThan(600));
    expect(saved['routeName'], 'Ghost Test Hill');

    await tester.runAsync(() async {
      api.stopGpxRoute();
      await api.disconnectTrainer();
      api.setDemoMode(enabled: false);
    });
    await tester.pump(const Duration(milliseconds: 300));
  });

  test('empty / invalid GPX never reaches the ghost store', () {
    expect(() => api.parseGpxXml(xml: ''), throwsA(anything));
    expect(() => api.parseGpxXml(xml: '<gpx></gpx>'), throwsA(anything));
  });
}
