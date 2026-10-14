import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart'
    show kAbandonedNote, kAbandonedTitle;
import 'package:tacx_desktop/src/ui/ride_summary_view.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';
import 'package:tacx_desktop/src/util/reveal_in_folder.dart';

Future<ProcessResult> _fakeRun(String exe, List<String> args) async =>
    ProcessResult(0, 0, '', '');

/// Matches the Rust fixture: 200 W for 1 h at FTP 200.
RideSummary _fixture({int ftp = 200}) => RideSummary(
  recordedS: 3600,
  ftpW: ftp,
  avgPowerW: 200,
  maxPowerW: 200,
  npW: 200,
  intensityFactor: ftp == 0 ? null : 1.0,
  tss: ftp == 0 ? null : 100,
  avgCadenceRpm: 90,
  maxCadenceRpm: 104,
  avgHeartRateBpm: 141.6,
  maxHeartRateBpm: 158,
  timeInZoneS: ftp == 0
      ? Uint32List(0)
      : Uint32List.fromList([0, 0, 0, 3600, 0, 0, 0]),
  bestPower: const [
    PowerBest(durationS: 5, watts: 200),
    PowerBest(durationS: 60, watts: 200),
    PowerBest(durationS: 300, watts: 200),
    PowerBest(durationS: 1200, watts: 200),
  ],
  best20MinW: 200,
  powerSeries: Float64List.fromList(List.filled(600, 200)),
  heartRateSeries: Float64List.fromList(List.filled(600, 140)),
  isDemo: false,
);

const _stats = RideStats(
  elapsedS: 3605,
  movingS: 3600,
  avgPowerW: 200,
  maxPowerW: 200,
  avgCadenceRpm: 90,
  energyKj: 720,
  distanceKm: 33.4,
  avgHeartRateBpm: 141.6,
  maxHeartRateBpm: 158,
  recording: false,
);

List<ElevSample> _climb() => [
  for (var i = 0; i <= 10; i++)
    ElevSample(
      distanceM: i * 100.0,
      // up 30 m, then down 20 m, then up 5 m
      elevM: switch (i) {
        <= 3 => 100.0 + i * 10,
        <= 7 => 130.0 - (i - 3) * 5,
        _ => 110.0 + (i - 7) * 5 / 3,
      },
      gradePct: 0,
      lat: 50 + i * 0.0009,
      lon: 4,
    ),
];

String _text(WidgetTester t, String key) {
  final w = t.widget(find.byKey(ValueKey(key)));
  if (w is Text) return w.data!;
  return t
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Text),
        ),
      )
      .map((e) => e.data)
      .join(' ');
}

Future<void> _pump(
  WidgetTester tester,
  RideSummaryData data, {
  VoidCallback? onSave,
  VoidCallback? onDone,
}) async {
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRideTheme(),
      home: Scaffold(
        body: Center(
          child: RideSummaryView(
            data: data,
            saveTcx: () async {
              (onSave ?? () {})();
              return '/tmp/tacx-ride-x.tcx';
            },
            reveal: Reveal(run: _fakeRun, os: 'linux'),
            onDone: onDone ?? () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('helpers', () {
    test('ghost line covers first finish, faster, slower, stopped', () {
      final geo = RouteGeo(_climb());
      RouteResult r({
        bool complete = true,
        double? f = 600,
        double? b,
        bool nb = false,
      }) => RouteResult(
        name: 'Hill',
        geo: geo,
        progressM: 420,
        complete: complete,
        elevGainM: 0,
        finishS: f,
        bestS: b,
        newBest: nb,
      );
      expect(
        RideSummaryView.ghostLine(r()),
        'Finished in 10:00 · first finish',
      );
      expect(
        RideSummaryView.ghostLine(r(b: 612, nb: true)),
        'Finished in 10:00 · −0:12 vs best · new best',
      );
      expect(
        RideSummaryView.ghostLine(r(b: 570)),
        'Finished in 10:00 · +0:30 vs best',
      );
      expect(
        RideSummaryView.ghostLine(r(complete: false)),
        'Stopped at 0.4 / 1.0 km',
      );
    });

    test('best labels', () {
      expect(RideSummaryView.bestLabel(5), '5 s');
      expect(RideSummaryView.bestLabel(60), '1 min');
      expect(RideSummaryView.bestLabel(1200), '20 min');
    });

    test('elevation gain over [0, progress] uses the 2 m hysteresis', () {
      final s = _climb();
      expect(elevGainUpTo(s, 0), 0);
      expect(elevGainUpTo(s, double.nan), 0);
      expect(elevGainUpTo(s, 150), closeTo(15, 1e-9)); // interpolated end
      expect(elevGainUpTo(s, 300), closeTo(30, 1e-9));
      expect(elevGainUpTo(s, 700), closeTo(30, 1e-9)); // descent adds nothing
      expect(elevGainUpTo(s, 1000), closeTo(35, 1e-9)); // +5 m after the dip
      // ±0.5 m jitter never counts.
      final flat = [
        for (var i = 0; i < 50; i++)
          ElevSample(
            distanceM: i * 10.0,
            elevM: 100 + (i.isEven ? 0.5 : -0.5),
            gradePct: 0,
            lat: 50,
            lon: 4,
          ),
      ];
      expect(elevGainUpTo(flat, 1e9), 0);
    });
  });

  testWidgets('fixture: NP 200, IF 1.00, TSS 100, bests and zones', (
    tester,
  ) async {
    var saved = 0, done = 0;
    await _pump(
      tester,
      RideSummaryData(
        title: 'Sweet spot 2x20',
        summary: _fixture(),
        stats: _stats,
        isDemo: false,
      ),
      onSave: () => saved++,
      onDone: () => done++,
    );
    expect(tester.takeException(), isNull);
    expect(_text(tester, 'sum-np'), contains('200 W'));
    expect(_text(tester, 'sum-if'), contains('1.00'));
    expect(_text(tester, 'sum-tss'), contains('100'));
    expect(_text(tester, 'sum-time'), contains('1:00:05'));
    expect(_text(tester, 'sum-best-1200'), contains('20 min'));
    expect(_text(tester, 'sum-best-1200'), contains('200 W'));
    final z4 = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('zone-bar-4')),
    );
    expect(z4.value, 1.0);
    expect(find.byKey(const ValueKey('summary-demo')), findsNothing);
    expect(find.byKey(const ValueKey('sum-power-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('sum-ghost')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('summary-save-tcx')));
    await tester.ensureVisible(find.byKey(const ValueKey('summary-done')));
    await tester.tap(find.byKey(const ValueKey('summary-done')));
    expect((saved, done), (1, 1));
  });

  testWidgets('QA c9: Abandoned summary says records were not updated', (
    tester,
  ) async {
    await _pump(
      tester,
      RideSummaryData(
        title: kAbandonedTitle,
        summary: _fixture(),
        stats: _stats,
        isDemo: false,
        note: kAbandonedNote,
      ),
    );
    expect(find.text('Ride ended — trainer lost for 30 min'), findsOneWidget);
    expect(_text(tester, 'summary-note'), contains("aren't updated"));
  });

  testWidgets('no FTP: IF/TSS blank, no zone bars, hint shown', (tester) async {
    await _pump(
      tester,
      RideSummaryData(
        title: 'Free ride',
        summary: _fixture(ftp: 0),
        stats: _stats,
        isDemo: false,
      ),
    );
    expect(_text(tester, 'sum-if'), contains('—'));
    expect(_text(tester, 'sum-tss'), contains('—'));
    expect(find.byKey(const ValueKey('zone-bar-1')), findsNothing);
    expect(find.textContaining('Set your FTP'), findsOneWidget);
  });

  testWidgets('demo GPX ride: DEMO tag, honest note, route + ghost result', (
    tester,
  ) async {
    final geo = RouteGeo(_climb());
    await _pump(
      tester,
      RideSummaryData(
        title: 'Hill',
        summary: _fixture(),
        stats: _stats,
        isDemo: true,
        route: RouteResult(
          name: 'Hill',
          geo: geo,
          progressM: 1000,
          complete: true,
          elevGainM: 35,
          finishS: 600,
          bestS: 612,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('summary-demo')), findsOneWidget);
    expect(find.textContaining('never saved as a ghost'), findsOneWidget);
    expect(_text(tester, 'sum-climb'), contains('35 m'));
    expect(_text(tester, 'sum-ghost'), 'Finished in 10:00 · −0:12 vs best');
    expect(find.byKey(const ValueKey('route-map-dots')), findsOneWidget);
  });

  testWidgets('short window: content scrolls, no overflow', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRideTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showRideSummary(
                  context,
                  data: RideSummaryData(
                    title: 'Hill',
                    summary: _fixture(),
                    stats: _stats,
                    isDemo: false,
                    route: RouteResult(
                      name: 'Hill',
                      geo: RouteGeo(_climb()),
                      progressM: 420,
                      complete: false,
                      elevGainM: 30,
                    ),
                  ),
                  saveTcx: () async => '/tmp/x.tcx',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('ride-summary')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('summary-done')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('summary-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ride-summary')), findsNothing);
  });
}
