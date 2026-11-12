import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ride/virtual_speed.dart';

void main() {
  void expectNear(double actual, double expected) {
    expect((actual - expected).abs(), lessThan(0.02), reason: 'actual $actual');
  }

  test('200 W flat at 83 kg is about 34 km/h', () {
    expectNear(virtualSpeedMps(powerW: 200, gradePct: 0, massKg: 83), 9.4719);
  });

  test('250 W at 5% is about 18 km/h', () {
    expectNear(virtualSpeedMps(powerW: 250, gradePct: 5, massKg: 83), 4.9826);
  });

  test('100 W flat', () {
    expectNear(virtualSpeedMps(powerW: 100, gradePct: 0, massKg: 83), 7.2568);
  });

  test('no power does not coast', () {
    expectNear(virtualSpeedMps(powerW: 0, gradePct: 0, massKg: 83), 0);
    expectNear(virtualSpeedMps(powerW: 0, gradePct: -5, massKg: 83), 0);
    expectNear(virtualSpeedMps(powerW: -50, gradePct: 0, massKg: 83), 0);
    expectNear(virtualSpeedMps(powerW: double.nan, gradePct: 0, massKg: 83), 0);
  });

  test('non-finite grade is flat and missing mass uses 83 kg', () {
    expectNear(
      virtualSpeedMps(powerW: 200, gradePct: double.nan, massKg: 83),
      9.4719,
    );
    expectNear(virtualSpeedMps(powerW: 200, gradePct: 0, massKg: 0), 9.4719);
  });

  test('downhill and steep grade', () {
    expectNear(virtualSpeedMps(powerW: 200, gradePct: -5, massKg: 83), 16.0527);
    expectNear(virtualSpeedMps(powerW: 400, gradePct: 8, massKg: 83), 5.2780);
  });
}
