import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/live_trend_chart.dart';

TrainerMetrics _m(double w, {double rpm = 90, int? hr}) =>
    TrainerMetrics(powerW: w, cadenceRpm: rpm, speedKmh: 30, heartRateBpm: hr);

void main() {
  group('TrendBuffer', () {
    test('samples at most once per second', () {
      final b = TrendBuffer();
      final t0 = DateTime(2026, 10, 7, 19);
      expect(b.offer(_m(200), t0), isTrue);
      expect(
        b.offer(_m(210), t0.add(const Duration(milliseconds: 250))),
        isFalse,
      );
      expect(
        b.offer(_m(220), t0.add(const Duration(milliseconds: 750))),
        isFalse,
      );
      expect(b.offer(_m(230), t0.add(const Duration(seconds: 1))), isTrue);
      expect(b.length, 2);
      expect(b.samples.last.powerW, 230);
    });

    test('keeps only the last capacity samples', () {
      final b = TrendBuffer(capacity: 5);
      final t0 = DateTime(2026);
      for (var i = 0; i < 12; i++) {
        b.offer(_m(i.toDouble()), t0.add(Duration(seconds: i)));
      }
      expect(b.length, 5);
      expect(b.samples.first.powerW, 7);
      expect(b.samples.last.powerW, 11);
    });

    test('drops zero / missing HR and negative power', () {
      final b = TrendBuffer();
      b.offer(_m(-5, hr: 0), DateTime(2026));
      expect(b.samples.single.powerW, 0);
      expect(b.samples.single.heartRateBpm, isNull);
    });

    test('clear empties and allows an immediate sample', () {
      final b = TrendBuffer();
      final t0 = DateTime(2026);
      b.offer(_m(100), t0);
      b.clear();
      expect(b.isEmpty, isTrue);
      expect(b.offer(_m(100), t0), isTrue);
    });
  });

  testWidgets('chart shows placeholder, then latest values with HR legend', (
    tester,
  ) async {
    final b = TrendBuffer();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveTrendChart(buffer: b)),
      ),
    );
    expect(
      find.text('Graph starts once the trainer sends data'),
      findsOneWidget,
    );
    expect(find.textContaining('bpm'), findsNothing);

    final t0 = DateTime(2026);
    b.offer(_m(180, rpm: 85), t0);
    b.offer(_m(240, rpm: 92, hr: 142), t0.add(const Duration(seconds: 1)));
    await tester.pump();

    expect(find.text('240 W'), findsOneWidget);
    expect(find.text('92 rpm'), findsOneWidget);
    expect(find.text('142 bpm'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
