import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/workout/route_prs.dart';

Climb _climb(String id, double s, double e) => Climb(
  id: id,
  startM: s,
  endM: e,
  gainM: 100,
  avgGrade: 5,
  maxGrade100M: 5,
  score: 10000,
  category: ClimbCat.cat4,
);

List<({double d, double t})> _ride(double secPerM) => [
  for (var d = 0.0; d <= 4000; d += 20) (d: d, t: d * secPerM),
];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('prs'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('T1: interpolated crossings give 401 s', () {
    final t = climbTimeS(
      const [
        (d: 990, t: 100),
        (d: 1010, t: 102),
        (d: 2990, t: 500),
        (d: 3010, t: 504),
      ],
      1000,
      3000,
    );
    expect(t, closeTo(401, 1e-9));
  });

  test('PR improves, never regresses, atomic file', () {
    final s = RoutePrStore(tmp);
    final c = [_climb('k:1000-3000', 1000, 3000)];
    final a = s.recordRide(
      routeKey: 'k',
      climbs: c,
      track: _ride(0.2),
      isDemo: false,
      finishS: 800,
    );
    expect(a.map((x) => x.label), ['Climb 1.0–3.0 km (+100 m)', 'Route']);
    expect(a.first.timeS, closeTo(400, 1e-6));
    final slower = s.recordRide(
      routeKey: 'k',
      climbs: c,
      track: _ride(0.3),
      isDemo: false,
      finishS: 1200,
    );
    expect(slower, isEmpty);
    expect(s.read('k').climbs['k:1000-3000']!.bestS, closeTo(400, 0.1));
    final faster = s.recordRide(
      routeKey: 'k',
      climbs: c,
      track: _ride(0.15),
      isDemo: false,
    );
    expect(faster.single.prevS, closeTo(400, 0.1));
    expect(File('${s.file('k').path}.tmp').existsSync(), isFalse);
  });

  test('Demo never writes', () {
    final s = RoutePrStore(tmp);
    final r = s.recordRide(
      routeKey: 'k',
      climbs: [_climb('k:1000-3000', 1000, 3000)],
      track: _ride(0.2),
      isDemo: true,
      finishS: 800,
    );
    expect(r, isEmpty);
    expect(s.file('k').existsSync(), isFalse);
  });

  test('loop repeats keep separate PRs; unfinished climb skipped', () {
    final s = RoutePrStore(tmp);
    final r = s.recordRide(
      routeKey: 'k',
      climbs: [
        _climb('k:1000-2000', 1000, 2000),
        _climb('k:3000-3900', 3000, 3900),
        _climb('k:3990-4500', 3990, 4500),
      ],
      track: _ride(0.2),
      isDemo: false,
    );
    expect(r.length, 2);
    expect(s.read('k').climbs.keys, ['k:1000-2000', 'k:3000-3900']);
  });

  test('other detector version: stale climb ids dropped', () {
    final s = RoutePrStore(tmp);
    s
        .file('k')
        .writeAsStringSync(
          '{"v":1,"detector":0,"routeKey":"k","routeBestS":700,"climbs":{"old":{"startM":1,"endM":600,"gainM":30,"bestS":10,"setAt":""}}}',
        );
    final p = s.read('k');
    expect(p.climbs, isEmpty);
    expect(p.routeBestS, 700);
  });
}
