import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// P1-S5: a spinner is never shown without a matching label, and every
/// in-progress state shows a spinner. P0-S3: status strips stay AA readable.
void main() {
  Future<void> pumpIndicator(
    WidgetTester tester,
    ConnectionStatusIndicator w,
  ) => tester.pumpWidget(
    MaterialApp(
      theme: buildRideTheme(),
      home: Scaffold(body: Center(child: w)),
    ),
  );

  final spinner = find.byKey(const ValueKey('connection-spinner'));
  final dot = find.byKey(const ValueKey('connection-dot'));
  String labelOf(WidgetTester t) => t
      .widget<Text>(find.byKey(const ValueKey('connection-state-label')))
      .data!;

  for (final s in ConnectionState.values) {
    testWidgets('state $s: spinner and label are paired', (tester) async {
      await pumpIndicator(tester, ConnectionStatusIndicator(state: s));
      final progress =
          s == ConnectionState.scanning ||
          s == ConnectionState.connecting ||
          s == ConnectionState.reconnecting;
      expect(spinner, progress ? findsOneWidget : findsNothing);
      expect(dot, progress ? findsNothing : findsOneWidget);
      final label = labelOf(tester);
      expect(label, startsWith(ConnectionStatusIndicator.stateLabel(s)));
      expect(label.contains('…'), progress);
    });
  }

  for (final busyLabel in [
    'Scanning',
    'Connecting',
    'Reconnecting',
    'Sending',
  ]) {
    testWidgets('busy "$busyLabel" shows spinner with its own label', (
      tester,
    ) async {
      await pumpIndicator(
        tester,
        ConnectionStatusIndicator(
          state: ConnectionState.connected,
          detail: 'Tacx Flux 2',
          busy: true,
          busyLabel: busyLabel,
        ),
      );
      expect(spinner, findsOneWidget);
      expect(dot, findsNothing);
      expect(labelOf(tester), '$busyLabel…');
    });
  }

  testWidgets('busy without label still says something', (tester) async {
    await pumpIndicator(
      tester,
      const ConnectionStatusIndicator(
        state: ConnectionState.disconnected,
        busy: true,
      ),
    );
    expect(spinner, findsOneWidget);
    expect(labelOf(tester), 'Working…');
  });

  testWidgets('settled connected keeps detail', (tester) async {
    await pumpIndicator(
      tester,
      const ConnectionStatusIndicator(
        state: ConnectionState.connected,
        detail: 'Tacx Flux 2 · FTMS',
      ),
    );
    expect(labelOf(tester), 'Connected · Tacx Flux 2 · FTMS');
  });

  const banners = {
    'bannerInfo (BT off)': RideColors.bannerInfo,
    'bannerError': RideColors.bannerError,
    'bannerWarn (link lost)': RideColors.bannerWarn,
  };
  for (final b in banners.entries) {
    test('white text on ${b.key} >= 4.5:1', () {
      final r = contrastRatio(Colors.white, b.value);
      expect(r, greaterThanOrEqualTo(4.5), reason: r.toStringAsFixed(2));
    });
  }
}
