import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/climbs_ui.dart';

const _c = Climb(
  id: 'k:1000-3000',
  startM: 1000,
  endM: 3000,
  gainM: 100,
  avgGrade: 5,
  maxGrade100M: 6,
  score: 10000,
  category: ClimbCat.cat4,
);

String _gpx() {
  final b = StringBuffer('<gpx><trk><name>F1</name><trkseg>');
  // 4 km north, 1 km flat · 2 km at 5 % · 1 km flat (≈10 m spacing).
  for (var i = 0; i <= 400; i++) {
    final d = i * 10.0;
    final e = d < 1000 ? 30.0 : (d < 3000 ? 30 + (d - 1000) * 0.05 : 130.0);
    b.write('<trkpt lat="${50 + d / 111195}" lon="4"><ele>$e</ele></trkpt>');
  }
  return '$b</trkseg></trk></gpx>';
}

void main() {
  setUpAll(() async => RustLib.init());

  test('labels and live chip text', () {
    expect(climbCatLabel(ClimbCat.climb), 'Climb');
    expect(climbCatLabel(ClimbCat.hc), 'HC');
    expect(climbSummary(_c), 'Cat 4 · 2.0 km · +100 m · 5.0 %');
    expect(climbLiveText(const [_c], 1800), 'Cat 4 · 1.2 km to top · 5.0 %');
    expect(climbLiveText(const [_c], 500), isNull);
    // QA c7 P2-f: metres under 1 km, "summit" for the last ~50 m.
    expect(climbLiveText(const [_c], 2400), 'Cat 4 · 600 m to top · 5.0 %');
    expect(climbLiveText(const [_c], 2960), 'Cat 4 · summit · 5.0 %');
    expect(climbLiveText(const [_c], 2000), 'Cat 4 · 1.0 km to top · 5.0 %');
    expect(climbCatLabel(ClimbCat.wall), 'Wall');
  });

  test('parse_gpx fills climbs (F1 through FRB)', () {
    final p = api.parseGpxXml(xml: _gpx());
    expect(p.climbs, hasLength(1));
    expect(p.climbs.single.category, ClimbCat.cat4);
    expect(p.climbs.single.id, startsWith('${p.routeKey}:'));
  });

  test('bands painter paints without throwing', () {
    final rec = PictureRecorder();
    ClimbBandsPainter(const [_c], 4000).paint(Canvas(rec), const Size(400, 80));
    rec.endRecording();
  });
}
