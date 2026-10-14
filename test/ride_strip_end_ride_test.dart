import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';

const _stats = RideStats(
  elapsedS: 3725,
  movingS: 3700,
  avgPowerW: 215,
  maxPowerW: 640,
  avgCadenceRpm: 88,
  avgHeartRateBpm: 0,
  maxHeartRateBpm: 0,
  energyKj: 790,
  distanceKm: 33.4,
  recording: true,
);

void main() {
  for (final size in const [Size(1280, 800), Size(800, 600)]) {
    testWidgets('QA c8 P2-b: End ride never rescales the strip @ $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<Rect> rideText({VoidCallback? onEnd}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: RideSummaryStrip(
                  stats: _stats,
                  onReset: () {},
                  onExport: () {},
                  onEndRide: onEnd,
                ),
              ),
            ),
          ),
        );
        return tester.getRect(find.byKey(const ValueKey('ride-ride')));
      }

      final without = await rideText();
      final withBtn = await rideText(onEnd: () {});
      expect(find.byKey(const ValueKey('end-free-ride')), findsOneWidget);
      expect(withBtn.height, closeTo(without.height, 0.01));
      expect(withBtn.left, closeTo(without.left, 0.01));
    });
  }
}
