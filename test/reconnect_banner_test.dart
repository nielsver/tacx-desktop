import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// P0-UX-4 / P1-BLE-4: auto-reconnect progress and the gave-up state.
void main() {
  ConnectionSnapshot snap({
    ConnectionState state = ConnectionState.reconnecting,
    int attempt = 2,
    int max = 4,
    int inS = 3,
    bool gaveUp = false,
  }) => ConnectionSnapshot(
    state: state,
    detail: 'from rust',
    protocol: ProtocolKind.ftms,
    isDemo: false,
    mode: ControlMode.erg,
    deviceName: 'Tacx Flux 2',
    supportsSimulation: true,
    reconnectAttempt: attempt,
    reconnectMaxAttempts: max,
    reconnectInS: inS,
    reconnectGaveUp: gaveUp,
  );

  Future<List<String>> pumpBanner(
    WidgetTester tester,
    ConnectionSnapshot s, {
    bool busy = false,
  }) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRideTheme(),
        home: Scaffold(
          body: Column(
            children: [
              ReconnectBanner(
                snap: s,
                busy: busy,
                onReconnect: () => calls.add('reconnect'),
                onDisconnect: () => calls.add('disconnect'),
              ),
            ],
          ),
        ),
      ),
    );
    return calls;
  }

  TextButton button(WidgetTester t, String key) =>
      t.widget<TextButton>(find.byKey(ValueKey(key)));

  void expectTapTargets(WidgetTester tester) {
    for (final e in find.byType(TextButton).evaluate()) {
      final box = e.renderObject! as RenderBox;
      expect(box.size.height, greaterThanOrEqualTo(kMinTapTarget));
    }
  }

  testWidgets('waiting for retry: attempt n/m with countdown', (tester) async {
    final calls = await pumpBanner(tester, snap());
    expect(find.byKey(const ValueKey('auto-reconnect-banner')), findsOneWidget);
    expect(
      find.text('Connection lost — reconnecting (2/4) in 3 s…'),
      findsOneWidget,
    );
    expect(button(tester, 'reconnect-now-action').onPressed, isNotNull);
    expect(button(tester, 'reconnect-stop-action').onPressed, isNotNull);
    expectTapTargets(tester);

    await tester.tap(find.byKey(const ValueKey('reconnect-now-action')));
    await tester.tap(find.byKey(const ValueKey('reconnect-stop-action')));
    expect(calls, ['reconnect', 'disconnect']);
  });

  testWidgets('attempt in flight: only Disconnect is offered', (tester) async {
    await pumpBanner(tester, snap(attempt: 3, inS: 0));
    expect(find.text('Connection lost — reconnecting (3/4)…'), findsOneWidget);
    expect(button(tester, 'reconnect-now-action').onPressed, isNull);
    expect(button(tester, 'reconnect-stop-action').onPressed, isNotNull);
  });

  testWidgets('busy action disables both actions', (tester) async {
    await pumpBanner(tester, snap(), busy: true);
    expect(button(tester, 'reconnect-now-action').onPressed, isNull);
    expect(button(tester, 'reconnect-stop-action').onPressed, isNull);
  });

  testWidgets('gave up: clear final state with manual Reconnect', (
    tester,
  ) async {
    final s = snap(
      state: ConnectionState.error,
      attempt: 4,
      inS: 0,
      gaveUp: true,
    );
    expect(ReconnectBanner.shows(s), isTrue);
    final calls = await pumpBanner(tester, s);
    expect(
      find.byKey(const ValueKey('reconnect-gave-up-banner')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('auto-reconnect-banner')), findsNothing);
    expect(
      find.textContaining("Couldn't reconnect after 4 tries"),
      findsOneWidget,
    );
    expectTapTargets(tester);
    await tester.tap(find.byKey(const ValueKey('reconnect-gave-up-action')));
    expect(calls, ['reconnect']);
  });

  test('plain link-lost / control-lost errors keep the existing strip', () {
    expect(
      ReconnectBanner.shows(snap(state: ConnectionState.error, attempt: 0)),
      isFalse,
    );
    expect(
      ReconnectBanner.shows(snap(state: ConnectionState.connected, attempt: 0)),
      isFalse,
    );
  });

  testWidgets('status indicator: spinner + "Reconnecting (2/4)…"', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRideTheme(),
        home: const Scaffold(
          body: Center(
            child: ConnectionStatusIndicator(
              state: ConnectionState.reconnecting,
              detail: 'Connection lost — reconnecting (2/4) in 3 s…',
              reconnectAttempt: 2,
              reconnectMaxAttempts: 4,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('connection-spinner')), findsOneWidget);
    expect(find.text('Reconnecting (2/4)…'), findsOneWidget);
  });
}
