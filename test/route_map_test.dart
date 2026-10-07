import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';

/// An L-shaped ~2 km route: north 1 km, then east 1 km.
List<ElevSample> _route() {
  final out = <ElevSample>[];
  for (var i = 0; i <= 10; i++) {
    out.add(
      ElevSample(
        distanceM: i * 100.0,
        elevM: 10,
        gradePct: 0,
        lat: 50 + i * 0.0009,
        lon: 4,
      ),
    );
  }
  for (var i = 1; i <= 10; i++) {
    out.add(
      ElevSample(
        distanceM: 1000 + i * 100.0,
        elevM: 10,
        gradePct: 0,
        lat: 50.009,
        lon: 4 + i * 0.0014,
      ),
    );
  }
  return out;
}

void main() {
  group('RouteGeo', () {
    test('fits inside the box, north up, start/end in place', () {
      final g = RouteGeo(_route())..fit(const Size(200, 100));
      for (final p in g.points) {
        expect(p.dx, inInclusiveRange(0, 200));
        expect(p.dy, inInclusiveRange(0, 100));
      }
      final start = g.points.first, corner = g.points[10], end = g.points.last;
      expect(corner.dy, lessThan(start.dy)); // north = up
      expect(end.dx, greaterThan(corner.dx)); // east = right
      expect((end.dy - corner.dy).abs(), lessThan(0.5));
    });

    test('at(d) interpolates along the line and clamps', () {
      final g = RouteGeo(_route())..fit(const Size(200, 200));
      expect(g.at(-5), g.points.first);
      expect(g.at(1e9), g.points.last);
      expect(g.at(double.nan), g.points.first);
      final mid = g.at(500);
      expect(mid.dx, closeTo(g.points.first.dx, 0.01));
      expect(mid.dy, closeTo((g.points[0].dy + g.points[10].dy) / 2, 0.5));
    });

    test('path is cached per size', () {
      final g = RouteGeo(_route())..fit(const Size(200, 200));
      final p1 = g.path;
      g.fit(const Size(200, 200));
      expect(identical(g.path, p1), isTrue);
      g.fit(const Size(300, 200));
      expect(identical(g.path, p1), isFalse);
    });

    test('single point / empty routes are not drawable', () {
      expect(RouteGeo(const []).isDrawable, isFalse);
      expect(RouteGeo(_route().take(1).toList()).isDrawable, isFalse);
    });
  });

  testWidgets('moving the rider repaints only the dot layer', (tester) async {
    final geo = RouteGeo(_route());
    final rider = ValueNotifier<double?>(0);
    final ghost = ValueNotifier<double?>(null);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 150,
            child: RouteMap(geo: geo, progressM: rider, ghostM: ghost),
          ),
        ),
      ),
    );
    final line0 = RouteLinePainter.debugPaints;
    final dots0 = RouteDotPainter.debugPaints;
    for (var i = 1; i <= 5; i++) {
      rider.value = i * 100.0;
      ghost.value = i * 90.0;
      await tester.pump();
    }
    expect(RouteLinePainter.debugPaints, line0, reason: 'route line repainted');
    expect(RouteDotPainter.debugPaints, greaterThanOrEqualTo(dots0 + 5));
  });

  group('OM1 locate / distanceToPoint', () {
    test('binary search agrees with a linear scan', () {
      final rnd = math.Random(7);
      var d = 0.0;
      final samples = <ElevSample>[];
      for (var i = 0; i < 500; i++) {
        // Some zero-length segments (duplicate distances) on purpose.
        d += i % 50 == 0 ? 0 : rnd.nextDouble() * 20;
        samples.add(
          ElevSample(
            distanceM: d,
            elevM: i.toDouble(),
            gradePct: 0,
            lat: 50,
            lon: 4 + i * 1e-4,
          ),
        );
      }
      final g = RouteGeo(samples);
      for (var k = 0; k < 2000; k++) {
        final m = rnd.nextDouble() * (d + 200) - 100;
        final (:i, :t) = g.locate(m);
        expect(i, inInclusiveRange(0, samples.length - 2));
        expect(t, inInclusiveRange(0.0, 1.0));
        // Reference: last index whose distance <= m.
        if (m > 0 && m < d) {
          var ref = 0;
          while (ref < samples.length - 2 && samples[ref + 1].distanceM <= m) {
            ref++;
          }
          expect(samples[i].distanceM, samples[ref].distanceM, reason: 'm=$m');
          final at =
              samples[i].distanceM +
              (samples[i + 1].distanceM - samples[i].distanceM) * t;
          expect(at, closeTo(m, 1e-6));
        }
      }
    });

    test('ends, NaN and interpolated values', () {
      final g = RouteGeo([
        const ElevSample(
          distanceM: 0,
          elevM: 100,
          gradePct: 5,
          lat: 50,
          lon: 4,
        ),
        const ElevSample(
          distanceM: 200,
          elevM: 110,
          gradePct: 5,
          lat: 50.002,
          lon: 4,
        ),
        const ElevSample(
          distanceM: 400,
          elevM: 100,
          gradePct: -5,
          lat: 50.004,
          lon: 4,
        ),
      ]);
      expect(g.locate(double.nan), (i: 0, t: 0.0));
      expect(g.locate(-1), (i: 0, t: 0.0));
      expect(g.locate(1e9), (i: 1, t: 1.0));
      final p = g.distanceToPoint(100);
      expect(p.elev, closeTo(105, 1e-9));
      expect(p.lat, closeTo(50.001, 1e-9));
      expect(p.grade, 5);
      expect(g.distanceToPoint(300).grade, closeTo(0, 1e-9));
      expect(g.distanceToPoint(400).grade, -5);
      expect(g.distanceToPoint(400).elev, 100);
      expect(g.elevRange, (100.0, 10.0));
      expect(elevCursorLabel(g, 100), '0.1 km · 105 m · 5.0 %');
    });

    test('flat profile gets a 1 m span', () {
      expect(profileElevRange(_route()), (10.0, 1.0));
      expect(profileElevRange(const []), (0.0, 1.0));
    });
  });

  group('OM4 nearestM', () {
    test('within 12 px of the line, else null', () {
      final g = RouteGeo(_route())..fit(const Size(200, 200));
      final p = g.at(1500);
      expect(g.nearestM(p), closeTo(1500, 100));
      expect(g.nearestM(p + const Offset(0, 5)), isNotNull);
      expect(g.nearestM(const Offset(199, 199)), isNull);
    });
  });

  testWidgets('OM3: hover moves only the ring layer', (tester) async {
    final geo = RouteGeo(_route());
    final rider = ValueNotifier<double?>(300);
    final ghost = ValueNotifier<double?>(250);
    final hover = ValueNotifier<double?>(null);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 150,
            child: RouteMap(
              geo: geo,
              progressM: rider,
              ghostM: ghost,
              hoverM: hover,
            ),
          ),
        ),
      ),
    );
    final line0 = RouteLinePainter.debugPaints;
    final dots0 = RouteDotPainter.debugPaints;
    final ring0 = RouteHoverPainter.debugPaints;
    for (var i = 1; i <= 4; i++) {
      hover.value = i * 400.0;
      await tester.pump();
    }
    hover.value = null;
    await tester.pump();
    expect(RouteHoverPainter.debugPaints, greaterThanOrEqualTo(ring0 + 5));
    expect(RouteDotPainter.debugPaints, dots0, reason: 'rider dot repainted');
    expect(RouteLinePainter.debugPaints, line0, reason: 'route line repainted');
  });

  testWidgets('OM2: ride ticks repaint only the chart cursor layer; hover '
      'and drag report metres and clear on exit', (tester) async {
    final samples = _route();
    final profile = GpxProfileInfo(
      name: 'L',
      distanceM: samples.last.distanceM,
      elevGainM: 0,
      samples: samples,
      routeKey: 'k',
    );
    final geo = RouteGeo(samples);
    final rider = ValueNotifier<double?>(0);
    final hover = ValueNotifier<double?>(null);
    final reported = <double?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 424,
              child: ElevProfileChart(
                profile: profile,
                geo: geo,
                riderM: rider,
                hoverM: hover,
                onHover: (m) {
                  reported.add(m);
                  hover.value = m;
                },
              ),
            ),
          ),
        ),
      ),
    );
    final static0 = ElevPainter.debugPaints;
    final cursor0 = ElevCursorPainter.debugPaints;
    for (var i = 1; i <= 8; i++) {
      rider.value = i * 200.0;
      await tester.pump();
    }
    expect(ElevPainter.debugPaints, static0, reason: 'profile redrawn on tick');
    expect(ElevCursorPainter.debugPaints, greaterThanOrEqualTo(cursor0 + 8));

    // Mouse hover over the middle of the plot ≈ half the route.
    final box = tester.getRect(find.byKey(const ValueKey('elev-cursor')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: box.centerLeft + const Offset(-50, 0));
    await mouse.moveTo(box.center);
    await tester.pump();
    expect(reported.last, closeTo(samples.last.distanceM / 2, 25));
    expect(ElevPainter.debugPaints, static0);
    await mouse.moveTo(box.center + const Offset(0, 200)); // leave
    await tester.pump();
    expect(reported.last, isNull);
    await mouse.removePointer();

    // Drag scrubs, then clears on release.
    final drag = await tester.startGesture(
      box.centerLeft + const Offset(10, 0),
    );
    await drag.moveBy(const Offset(60, 0));
    await drag.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(reported.last, isNotNull);
    await drag.up();
    await tester.pump();
    expect(reported.last, isNull);
    expect(tester.takeException(), isNull);
  });
}
