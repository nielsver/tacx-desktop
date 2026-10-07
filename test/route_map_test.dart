import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
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
}
