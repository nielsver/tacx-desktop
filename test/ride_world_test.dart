import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ride_world.dart';

void main() {
  testWidgets('shows virtual speed and keeps pedalling', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 200,
            child: RideWorld(speedMps: 10, cadenceRpm: 90),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('36 km/h'), findsOneWidget);
    expect(find.text('Virtual speed · from power'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Virtual ride, 36 kilometers per hour'),
      findsOneWidget,
    );
  });

  testWidgets('stands still at zero speed', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 200,
            child: RideWorld(speedMps: 0, cadenceRpm: 0),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('0 km/h'), findsOneWidget);
  });

  testWidgets('a zero canvas does not throw', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 0,
          height: 0,
          child: RideWorld(speedMps: 8, cadenceRpm: 80),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(RideWorld), findsOneWidget);
  });
}
