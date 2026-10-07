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

  late Directory tmp;
  late GhostStore store;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ghost_demo');
    store = GhostStore(Directory('${tmp.path}/ghosts'));
    GhostStore.debugDirOverride = store.dir;
  });

  tearDown(() {
    GhostStore.debugDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  testWidgets('Demo GPX ride shows ghost chip and never saves a best (G2)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final profile = api.parseGpxXml(xml: _gpx);
    final key = profile.routeKey;
    final file = store.bestFile(key);
    // Seed a slow previous best (10 minutes) so the ghost is behind us —
    // this is written directly so Demo mode never has to.
    expect(
      store.saveIfBest(
        key,
        profile.name,
        profile.distanceM,
        (() {
          final r = AttemptRecorder()
            ..offer(0, 0)
            ..finish(600, profile.distanceM);
          return r.toTrack();
        })(),
      ),
      isTrue,
    );
    expect(file.existsSync(), isTrue);
    final before = file.readAsStringSync();

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
    // scrollUntilVisible builds the target; ensureVisible then brings it
    // fully on screen (a half-visible button at the panel edge passed
    // scrollUntilVisible but missed the tap with CI fonts).
    Future<void> reveal(Finder f, {double delta = 120}) async {
      await tester.scrollUntilVisible(f, delta, scrollable: panelScroll.first);
      await tester.ensureVisible(f);
      await tester.pump();
    }

    await reveal(find.byKey(const ValueKey('gpx-paste')));
    await tester.tap(find.byKey(const ValueKey('gpx-paste')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await reveal(find.byKey(const ValueKey('route-best')));
    expect(find.textContaining('Best 10:00'), findsOneWidget);

    await reveal(find.byKey(const ValueKey('gpx-start')), delta: -120);
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
    expect(find.textContaining('−'), findsWidgets);

    for (var i = 0; i < 40 && !api.getRouteStatus().complete; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 260));
    }
    await tester.pump(const Duration(milliseconds: 260));
    expect(api.getRouteStatus().complete, isTrue);
    expect(find.byKey(const ValueKey('ghost-delta-chip')), findsNothing);

    // Demo must never overwrite the seeded best (G2).
    expect(file.readAsStringSync(), before);
    await reveal(find.byKey(const ValueKey('ghost-reset-best')));
    expect(find.textContaining('Best 10:00'), findsOneWidget);

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
