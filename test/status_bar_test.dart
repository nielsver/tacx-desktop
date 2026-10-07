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

final _link = ValueNotifier(
  const LinkHealth(packetsPerS: 4, lastPacketAgeMs: 250, level: LinkLevel.good),
);
final _metrics = ValueNotifier(
  const TrainerMetrics(powerW: 0, cadenceRpm: 0, speedKmh: 0),
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
        'HR 142 · strap',
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
        'HR — · strap',
      );
      expect(
        RideStatusBar.hrLabel(_noStrap, trainerBpm: 131),
        'HR 131 · trainer',
      );
    });
  });

  testWidgets(
    'bar shows trainer, mode, HR, REC + clock; demo shows as Demo trainer',
    (tester) async {
      final ride = ValueNotifier(_ride(754));
      await tester.pumpWidget(
        _host(
          RideStatusBar(
            link: _link,
            metrics: _metrics,
            snap: _snap(),
            strap: _noStrap,
            ride: ride,
          ),
        ),
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
            link: _link,
            metrics: _metrics,
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
      _host(
        RideStatusBar(
          link: _link,
          metrics: _metrics,
          snap: _snap(),
          strap: _noStrap,
          ride: ride,
        ),
      ),
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
          link: _link,
          metrics: _metrics,
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

  group('link health', () {
    test('label: rate and last-packet age, waiting before first packet', () {
      expect(
        RideStatusBar.linkLabel(
          const LinkHealth(
            packetsPerS: 4,
            lastPacketAgeMs: 250,
            level: LinkLevel.good,
          ),
        ),
        '4.0/s · 0.3 s',
      );
      expect(
        RideStatusBar.linkLabel(
          const LinkHealth(
            packetsPerS: 0,
            lastPacketAgeMs: 125000,
            level: LinkLevel.lost,
          ),
        ),
        '0.0/s · 2 min',
      );
      expect(
        RideStatusBar.linkLabel(
          const LinkHealth(packetsPerS: 0, level: LinkLevel.noData),
        ),
        'waiting for data',
      );
    });

    test('colour per level (green < 1.5 s, amber < 4 s, red)', () {
      expect(RideStatusBar.linkColor(LinkLevel.good), RideColors.ok);
      expect(RideStatusBar.linkColor(LinkLevel.stale), RideColors.warn);
      expect(RideStatusBar.linkColor(LinkLevel.lost), RideColors.danger);
      expect(RideStatusBar.linkColor(LinkLevel.noData), RideColors.textMuted);
    });

    test('reconnect countdown is visible', () {
      final s = ConnectionSnapshot(
        state: ConnectionState.reconnecting,
        detail: '',
        protocol: ProtocolKind.ftms,
        isDemo: false,
        mode: ControlMode.erg,
        deviceName: 'KICKR',
        supportsSimulation: true,
        reconnectAttempt: 2,
        reconnectMaxAttempts: 5,
        reconnectInS: 3,
        reconnectGaveUp: false,
      );
      expect(RideStatusBar.trainerLabel(s), 'Reconnecting KICKR in 3 s · 2/5');
      expect(
        RideStatusBar.reconnectLabel(
          ConnectionSnapshot(
            state: ConnectionState.reconnecting,
            detail: '',
            protocol: ProtocolKind.ftms,
            isDemo: false,
            mode: ControlMode.erg,
            deviceName: '',
            supportsSimulation: true,
            reconnectAttempt: 1,
            reconnectMaxAttempts: 5,
            reconnectInS: 0,
            reconnectGaveUp: false,
          ),
        ),
        'Reconnecting… · 1/5',
      );
      expect(
        RideStatusBar.reconnectLabel(
          ConnectionSnapshot(
            state: ConnectionState.reconnecting,
            detail: '',
            protocol: ProtocolKind.ftms,
            isDemo: false,
            mode: ControlMode.erg,
            deviceName: 'KICKR',
            supportsSimulation: true,
            reconnectAttempt: 5,
            reconnectMaxAttempts: 5,
            reconnectInS: 0,
            reconnectGaveUp: true,
          ),
        ),
        'Link lost · press Reconnect',
      );
    });

    testWidgets('a stalled trainer turns the dot amber then red, text too', (
      tester,
    ) async {
      final link = ValueNotifier(
        const LinkHealth(
          packetsPerS: 4,
          lastPacketAgeMs: 200,
          level: LinkLevel.good,
        ),
      );
      final ride = ValueNotifier(_ride(10));
      await tester.pumpWidget(
        _host(
          RideStatusBar(
            snap: _snap(),
            strap: _noStrap,
            ride: ride,
            link: link,
            metrics: _metrics,
          ),
        ),
      );
      Color dot() =>
          ((tester.widget(
                            find.descendant(
                              of: find.byKey(const ValueKey('status-link-dot')),
                              matching: find.byType(Container),
                            ),
                          )
                          as Container)
                      .decoration!
                  as BoxDecoration)
              .color!;
      expect(dot(), RideColors.ok);
      expect(_text(tester, 'status-link'), '4.0/s · 0.2 s');

      link.value = const LinkHealth(
        packetsPerS: 2.4,
        lastPacketAgeMs: 2100,
        level: LinkLevel.stale,
      );
      await tester.pump();
      expect(dot(), RideColors.warn);
      expect(_text(tester, 'status-link'), '2.4/s · 2.1 s');

      link.value = const LinkHealth(
        packetsPerS: 0,
        lastPacketAgeMs: 6000,
        level: LinkLevel.lost,
      );
      await tester.pump();
      expect(dot(), RideColors.danger);
      final t = tester.widget<Text>(find.byKey(const ValueKey('status-link')));
      expect(t.style!.color, RideColors.danger);

      // Disconnected: no link readout at all.
      await tester.pumpWidget(
        _host(
          RideStatusBar(
            snap: _snap(state: ConnectionState.disconnected),
            strap: _noStrap,
            ride: ride,
            link: link,
            metrics: _metrics,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('status-link')), findsNothing);
      link.dispose();
      ride.dispose();
    });

    testWidgets('trainer-relayed HR shows with its source', (tester) async {
      final ride = ValueNotifier(_ride(10));
      final m = ValueNotifier(
        const TrainerMetrics(
          powerW: 0,
          cadenceRpm: 0,
          speedKmh: 0,
          heartRateBpm: 128,
        ),
      );
      await tester.pumpWidget(
        _host(
          RideStatusBar(
            snap: _snap(),
            strap: _noStrap,
            ride: ride,
            link: _link,
            metrics: m,
          ),
        ),
      );
      expect(_text(tester, 'status-hr'), 'HR 128 · trainer');
      ride.dispose();
      m.dispose();
    });
  });
}
