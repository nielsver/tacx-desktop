import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/status_bar.dart';

ConnectionSnapshot _snap({
  ConnectionState state = ConnectionState.connected,
  ProtocolKind protocol = ProtocolKind.ftms,
  ControlMode mode = ControlMode.erg,
  String name = 'KICKR CORE 1A2B',
  bool demo = false,
}) => ConnectionSnapshot(
  state: state,
  detail: '',
  protocol: protocol,
  isDemo: demo,
  mode: mode,
  deviceName: name,
  supportsSimulation: true,
  reconnectAttempt: 0,
  reconnectMaxAttempts: 0,
  reconnectInS: 0,
  reconnectGaveUp: false,
);

const _noStrap = HrStrapStatus(
  state: HrStrapState.disconnected,
  deviceId: '',
  deviceName: '',
  detail: '',
);

RideStats _ride(int s, {bool rec = true}) => RideStats(
  elapsedS: s,
  movingS: s,
  avgPowerW: 0,
  maxPowerW: 0,
  avgCadenceRpm: 0,
  energyKj: 0,
  distanceKm: 0,
  avgHeartRateBpm: 0,
  maxHeartRateBpm: 0,
  recording: rec,
);

Widget _host(Widget child) => MaterialApp(
  theme: buildRideTheme(),
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

String _text(WidgetTester t, String key) =>
    (t.widget(find.byKey(ValueKey(key))) as Text).data!;

void main() {
  group('labels', () {
    test('trainer label per state and protocol', () {
      expect(RideStatusBar.trainerLabel(_snap()), 'KICKR CORE 1A2B · FTMS');
      expect(
        RideStatusBar.trainerLabel(
          _snap(protocol: ProtocolKind.tacxFecBle, name: 'Tacx Flux 2'),
        ),
        'Tacx Flux 2 · FE-C',
      );
      expect(RideStatusBar.trainerLabel(_snap(name: '  ')), 'FTMS');
      expect(
        RideStatusBar.trainerLabel(_snap(state: ConnectionState.disconnected)),
        'No trainer',
      );
      expect(
        RideStatusBar.trainerLabel(_snap(state: ConnectionState.reconnecting)),
        'Reconnecting KICKR CORE 1A2B…',
      );
      expect(
        RideStatusBar.trainerLabel(_snap(state: ConnectionState.error)),
        'KICKR CORE 1A2B · error',
      );
      expect(RideStatusBar.trainerLabel(_snap(demo: true)), 'Demo trainer');
    });

    test('mode only while connected', () {
      expect(RideStatusBar.modeLabel(_snap()), 'ERG');
      expect(
        RideStatusBar.modeLabel(_snap(mode: ControlMode.simulation)),
        'SIM',
      );
      expect(
        RideStatusBar.modeLabel(_snap(mode: ControlMode.resistance)),
        'RES',
      );
      expect(
        RideStatusBar.modeLabel(_snap(mode: ControlMode.idle)),
        'Free ride',
      );
      expect(
        RideStatusBar.modeLabel(_snap(state: ConnectionState.reconnecting)),
        isNull,
      );
    });

    test('state colours and clock', () {
      expect(
        RideStatusBar.trainerColor(ConnectionState.connected),
        RideColors.ok,
      );
      expect(
        RideStatusBar.trainerColor(ConnectionState.reconnecting),
        RideColors.warn,
      );
      expect(
        RideStatusBar.trainerColor(ConnectionState.error),
        RideColors.danger,
      );
      expect(RideStatusBar.clock(0), '00:00');
      expect(RideStatusBar.clock(-3), '00:00');
      expect(RideStatusBar.clock(3725), '1:02:05');
    });

    test('HR label', () {
      expect(RideStatusBar.hrLabel(_noStrap), 'HR off');
      expect(
        RideStatusBar.hrLabel(
          const HrStrapStatus(
            state: HrStrapState.connected,
            deviceId: 'x',
            deviceName: 'Polar H10',
            detail: '',
            heartRateBpm: 142,
          ),
        ),
        'HR 142',
      );
      expect(
        RideStatusBar.hrLabel(
          const HrStrapStatus(
            state: HrStrapState.connected,
            deviceId: 'x',
            deviceName: 'Polar H10',
            detail: '',
          ),
        ),
        'HR —',
      );
    });
  });

  testWidgets(
    'bar shows trainer, mode, HR, REC + clock; demo shows as Demo trainer',
    (tester) async {
      final ride = ValueNotifier(_ride(754));
      await tester.pumpWidget(
        _host(RideStatusBar(snap: _snap(), strap: _noStrap, ride: ride)),
      );
      expect(_text(tester, 'status-trainer'), 'KICKR CORE 1A2B · FTMS');
      expect(_text(tester, 'status-mode'), 'ERG');
      expect(_text(tester, 'status-hr'), 'HR off');
      expect(_text(tester, 'status-rec'), 'REC');
      expect(_text(tester, 'status-clock'), '12:34');

      ride.value = _ride(755, rec: false);
      await tester.pump();
      expect(_text(tester, 'status-clock'), '12:35');
      expect(_text(tester, 'status-rec'), 'Not recording');

      await tester.pumpWidget(
        _host(
          RideStatusBar(
            snap: _snap(demo: true, protocol: ProtocolKind.demo),
            strap: _noStrap,
            ride: ride,
          ),
        ),
      );
      expect(
        find.text('DEMO'),
        findsNothing,
        reason: 'header owns the DEMO chip',
      );
      expect(_text(tester, 'status-trainer'), 'Demo trainer');
      ride.dispose();
    },
  );

  testWidgets('clock ticks without rebuilding the rest of the bar', (
    tester,
  ) async {
    final ride = ValueNotifier(_ride(1));
    await tester.pumpWidget(
      _host(RideStatusBar(snap: _snap(), strap: _noStrap, ride: ride)),
    );
    final trainer = tester.element(
      find.byKey(const ValueKey('status-trainer')),
    );
    final before = trainer.widget;
    for (var i = 2; i < 10; i++) {
      ride.value = _ride(i);
      await tester.pump();
    }
    expect(identical(trainer.widget, before), isTrue);
    ride.dispose();
  });

  testWidgets('long device names ellipsize at 800 px without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ride = ValueNotifier(_ride(36000));
    await tester.pumpWidget(
      _host(
        RideStatusBar(
          snap: _snap(name: 'A very long trainer name ' * 6, demo: false),
          strap: const HrStrapStatus(
            state: HrStrapState.connected,
            deviceId: 'x',
            deviceName: 'Polar H10',
            detail: '',
            heartRateBpm: 188,
          ),
          ride: ride,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_text(tester, 'status-clock'), '10:00:00');
    ride.dispose();
  });
}
