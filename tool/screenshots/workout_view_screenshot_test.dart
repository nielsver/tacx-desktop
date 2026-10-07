// Renders the workout ride view to a PNG with real fonts (manual visual check).
//
//   SCREENSHOT_OUT=/tmp/workout_view.png FONT_DIR=<dir with Roboto-*.ttf> \
//     flutter test tool/screenshots/workout_view_screenshot_test.dart
//
// Not part of `flutter test` in CI (lives outside test/). Skips without env.
// Note: `flutter test` runs the engine with --use-test-fonts, so on some
// Flutter versions glyphs still render as boxes; layout, colours and the
// graph are accurate.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/workout_ride_view.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';

/// Registers Roboto under both 'Roboto' (the ride theme) and 'FlutterTest'
/// (the test default used by painters' TextStyles) so no glyph is a box.
Future<void> _loadFonts(String dir) async {
  for (final family in ['Roboto', 'FlutterTest']) {
    final loader = FontLoader(family);
    for (final f in Directory(dir).listSync().whereType<File>()) {
      if (f.path.endsWith('.ttf') && f.path.contains('Roboto-')) {
        final bytes = f.readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
    }
    await loader.load();
  }
}

void main() {
  final out = Platform.environment['SCREENSHOT_OUT'];
  final fonts = Platform.environment['FONT_DIR'];

  setUpAll(() async {
    if (fonts != null) await _loadFonts(fonts);
  });

  testWidgets('workout ride view screenshot', (tester) async {
    final steps = <String>[
      '{"kind":"ramp","durationS":600,"wattsStart":110,"wattsEnd":190}',
      for (var i = 0; i < 3; i++) ...[
        '{"kind":"erg","durationS":480,"watts":240}',
        '{"kind":"erg","durationS":240,"watts":140}',
      ],
      '{"kind":"ramp","durationS":300,"wattsStart":150,"wattsEnd":100}',
    ];
    final plan = WorkoutPlan.tryParse(
      '{"id":"shot","name":"Sweet spot 3×8","steps":[${steps.join(',')}]}',
    )!;
    // 20 s before the end of the second work interval.
    final stepIndex = 3;
    final remaining = 2.4;
    final now = plan.startOf(stepIndex + 1) - remaining;
    final trace = WorkoutTrace();
    final rnd = math.Random(7);
    for (var t = 0.0; t <= now; t += 1) {
      final target = plan.targetAt(t) ?? 0;
      trace.offer('shot', t, target + (rnd.nextDouble() - 0.5) * 24);
    }

    const size = Size(1366, 360);
    await tester.binding.setSurfaceSize(size);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildRideTheme(),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Container(
              color: RideColors.bg,
              padding: const EdgeInsets.all(12),
              child: WorkoutRideView(
                plan: plan,
                progress: WorkoutProgress(
                  stepIndex: stepIndex,
                  remainingS: remaining,
                ),
                trace: trace,
                ftp: 250,
                large: true,
                onEditFtp: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(out!).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }, skip: out == null || fonts == null);
}
