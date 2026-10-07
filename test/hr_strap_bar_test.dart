import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/hr_strap_bar.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

HrStrapStatus _status(HrStrapState state, {int? bpm, String detail = ''}) =>
    HrStrapStatus(
      state: state,
      deviceId: 'hrm-1',
      deviceName: 'Polar H10',
      detail: detail,
      heartRateBpm: bpm,
    );

const _straps = [
  DiscoveredDevice(
    id: 'hrm-1',
    name: 'Polar H10',
    rssi: -60,
    protocolHint: 'heart_rate',
  ),
  DiscoveredDevice(
    id: 'hrm-2',
    name: 'HRM-Pro',
    rssi: -70,
    protocolHint: 'heart_rate',
  ),
];

void main() {
  final calls = <String>[];

  Future<void> pump(
    WidgetTester tester,
    HrStrapStatus status, {
    List<DiscoveredDevice> straps = const [],
    bool searching = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HeartRateStrapBar(
            status: status,
            straps: straps,
            selectedId: straps.isEmpty ? null : straps.first.id,
            searching: searching,
            onSearch: () => calls.add('search'),
            onSelect: (id) => calls.add('select $id'),
            onConnect: () => calls.add('connect'),
            onDisconnect: () => calls.add('disconnect'),
          ),
        ),
      ),
    );
  }

  void expectTapTargets(WidgetTester tester) {
    for (final e
        in find.byWidgetPredicate((w) => w is ButtonStyleButton).evaluate()) {
      expect(
        (e.renderObject! as RenderBox).size.height,
        greaterThanOrEqualTo(kMinTapTarget),
      );
    }
  }

  setUp(calls.clear);

  testWidgets('no strap: hint + Find HR strap', (tester) async {
    await pump(tester, _status(HrStrapState.disconnected));
    expect(find.textContaining('No heart-rate strap'), findsOneWidget);
    await tester.tap(find.text('Find HR strap'));
    expect(calls, ['search']);
    expect(find.byKey(const ValueKey('hr-strap-picker')), findsNothing);
    expectTapTargets(tester);
  });

  testWidgets('found straps: picker + Connect strap', (tester) async {
    await pump(tester, _status(HrStrapState.disconnected), straps: _straps);
    expect(find.byKey(const ValueKey('hr-strap-picker')), findsOneWidget);
    expect(find.text('Search again'), findsOneWidget);
    await tester.tap(find.text('Connect strap'));
    expect(calls, ['connect']);
    expectTapTargets(tester);
  });

  testWidgets('connected: live bpm + Disconnect strap', (tester) async {
    await pump(
      tester,
      _status(HrStrapState.connected, bpm: 142),
      straps: _straps,
    );
    expect(find.text('Polar H10 · 142 bpm'), findsOneWidget);
    expect(find.text('Connect strap'), findsNothing);
    await tester.tap(find.text('Disconnect strap'));
    expect(calls, ['disconnect']);
  });

  testWidgets('connected without contact asks to wear the strap', (
    tester,
  ) async {
    await pump(tester, _status(HrStrapState.connected));
    expect(find.textContaining('waiting for heart rate'), findsOneWidget);
  });

  testWidgets('error detail shown; searching disables the button', (
    tester,
  ) async {
    await pump(
      tester,
      _status(HrStrapState.error, detail: 'Strap connect failed'),
    );
    expect(find.text('Strap connect failed'), findsOneWidget);
    await pump(tester, _status(HrStrapState.disconnected), searching: true);
    expect(find.textContaining('Searching'), findsOneWidget);
    final btn = tester.widget<TextButton>(
      find.byKey(const ValueKey('hr-strap-search')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('narrow window does not overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HeartRateStrapBar(
            status: _status(HrStrapState.disconnected),
            straps: _straps,
            selectedId: 'hrm-1',
            searching: false,
            onSearch: () {},
            onSelect: (_) {},
            onConnect: () {},
            onDisconnect: () {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('hr-strap-picker')), findsNothing);
    expect(find.text('Connect strap'), findsOneWidget);
  });

  testWidgets('single strap: no picker, named in the status', (tester) async {
    await pump(
      tester,
      _status(HrStrapState.disconnected),
      straps: [_straps.first],
    );
    expect(find.text('Found Polar H10'), findsOneWidget);
    expect(find.byKey(const ValueKey('hr-strap-picker')), findsNothing);
  });
}
