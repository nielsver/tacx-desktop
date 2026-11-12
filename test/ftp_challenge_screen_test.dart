import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/challenge/ftp_challenge.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ftp_challenge_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  /// The default 800×600 surface clips the challenge column, so buttons
  /// below the clock are never built.
  Future<void> _tall(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('challenge is available without a heart-rate sensor', (
    tester,
  ) async {
    await _tall(tester);
    api.setDemoMode(enabled: true);
    await tester.runAsync(api.connectTrainer);
    await tester.runAsync(api.disconnectHeartRateStrap);
    await tester.pumpWidget(
      MaterialApp(home: FtpChallengeScreen(challenge: FtpChallenge())),
    );
    await tester.pump();

    expect(find.text('FTP assessment'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('Heart rate is optional'));
    await tester.pump();
    expect(find.textContaining('Heart rate is optional'), findsOneWidget);
    expect(find.text('Start warm-up'), findsOneWidget);
    expect(find.text('DEMO MODE · Simulated training data'), findsOneWidget);
  });

  testWidgets('paused challenge can reconnect after trainer disconnects', (
    tester,
  ) async {
    await _tall(tester);
    api.setDemoMode(enabled: true);
    await tester.runAsync(api.connectTrainer);
    await tester.pumpWidget(
      MaterialApp(home: FtpChallengeScreen(challenge: FtpChallenge())),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Start warm-up'));
    await tester.tap(find.text('Start warm-up'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Pause'));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    await tester.runAsync(api.disconnectTrainer);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.ensureVisible(find.text('Reconnect trainer'));
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Reconnect trainer'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Reconnect trainer'), findsNothing);
  });

  testWidgets('ending early does not show an FTP result', (tester) async {
    await _tall(tester);
    api.setDemoMode(enabled: true);
    await tester.runAsync(api.connectTrainer);
    await tester.pumpWidget(
      MaterialApp(home: FtpChallengeScreen(challenge: FtpChallenge())),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Start warm-up'));
    await tester.pump();
    await tester.tap(find.text('Start warm-up'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('WARM-UP'), findsOneWidget);
    await tester.ensureVisible(find.text('End challenge'));
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.text('End challenge')));
    await tester.pump();
    expect(find.text('Challenge ended'), findsOneWidget);
    expect(find.text('Estimated FTP'), findsNothing);
  });

  testWidgets('trainer loss interrupts the challenge until explicit resume', (
    tester,
  ) async {
    await _tall(tester);
    api.setDemoMode(enabled: true);
    await tester.runAsync(api.connectTrainer);
    await tester.pumpWidget(
      MaterialApp(home: FtpChallengeScreen(challenge: FtpChallenge())),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Start warm-up'));
    await tester.pump();
    await tester.tap(find.text('Start warm-up'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Pause'));
    await tester.pump();
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pump();

    await tester.runAsync(api.disconnectTrainer);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('INTERRUPTED'), findsOneWidget);
    expect(find.text('Reconnect trainer'), findsOneWidget);

    await tester.tap(find.text('Reconnect trainer'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('Resume challenge'), findsOneWidget);
    await tester.tap(find.text('Resume challenge'));
    await tester.pump();
    expect(find.text('INTERRUPTED'), findsNothing);
  });
}
