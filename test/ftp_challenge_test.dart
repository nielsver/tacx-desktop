import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/challenge/ftp_challenge.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1);

  test('completes warmup then calculates FTP from effort power', () {
    final c = FtpChallenge(
      warmupDuration: const Duration(seconds: 2),
      effortDuration: const Duration(seconds: 4),
    );
    c.start(t0);
    c.tick(t0.add(const Duration(seconds: 1)), powerW: 20);
    c.tick(t0.add(const Duration(seconds: 2)), powerW: 200);
    expect(c.snapshot.phase, FtpChallengePhase.effort);
    c.tick(t0.add(const Duration(seconds: 3)), powerW: 200);
    c.tick(t0.add(const Duration(seconds: 4)), powerW: 200);
    c.tick(t0.add(const Duration(seconds: 5)), powerW: 200);
    c.tick(t0.add(const Duration(seconds: 6)), powerW: 200);
    expect(c.snapshot.phase, FtpChallengePhase.completed);
    expect(c.snapshot.estimatedFtpW, 190);
  });

  test('paused time is excluded and ending early has no estimate', () {
    final c = FtpChallenge(
      warmupDuration: const Duration(seconds: 1),
      effortDuration: const Duration(seconds: 4),
    );
    c.start(t0);
    c.tick(t0.add(const Duration(seconds: 1)), powerW: 200);
    c.tick(t0.add(const Duration(seconds: 2)), powerW: 200);
    c.pause(t0.add(const Duration(seconds: 2)));
    c.resume(t0.add(const Duration(seconds: 7)));
    c.end(t0.add(const Duration(seconds: 8)));
    expect(c.snapshot.effortElapsed, const Duration(seconds: 2));
    expect(c.snapshot.estimatedFtpW, isNull);
  });

  test(
    'trainer interruption preserves the effort phase and excludes the gap',
    () {
      final c = FtpChallenge(
        warmupDuration: Duration.zero,
        effortDuration: const Duration(seconds: 8),
      );
      c.start(t0);
      c.tick(t0.add(const Duration(seconds: 1)), powerW: 200);
      c.interrupt(t0.add(const Duration(seconds: 2)));
      expect(c.snapshot.phase, FtpChallengePhase.interrupted);
      c.resume(t0.add(const Duration(seconds: 20)));
      c.tick(t0.add(const Duration(seconds: 21)), powerW: 180);
      expect(c.snapshot.effortElapsed, const Duration(seconds: 3));
      c.tick(t0.add(const Duration(seconds: 26)), powerW: 180);
      expect(c.snapshot.phase, FtpChallengePhase.completed);
      expect(c.snapshot.effortElapsed, const Duration(seconds: 8));
    },
  );

  test('interrupted snapshots preserve the phase clock and remaining time', () {
    final c = FtpChallenge(
      warmupDuration: const Duration(seconds: 10),
      effortDuration: const Duration(seconds: 20),
    );
    c.start(t0);
    c.tick(t0.add(const Duration(seconds: 3)), powerW: null);
    c.interrupt(t0.add(const Duration(seconds: 4)));
    expect(c.snapshot.phaseElapsed, const Duration(seconds: 4));
    expect(c.snapshot.phaseRemaining, const Duration(seconds: 6));
  });

  test(
    'a delayed tick crosses the warmup boundary without using warmup power',
    () {
      final c = FtpChallenge(
        warmupDuration: const Duration(seconds: 2),
        effortDuration: const Duration(seconds: 4),
      );
      c.start(t0);
      c.tick(t0.add(const Duration(seconds: 1)), powerW: 300);
      c.tick(t0.add(const Duration(seconds: 3)), powerW: 100);
      expect(c.snapshot.phase, FtpChallengePhase.effort);
      expect(c.snapshot.effortElapsed, const Duration(seconds: 1));
      expect(c.snapshot.averagePowerW, isNull);
      c.tick(t0.add(const Duration(seconds: 6)), powerW: 200);
      expect(c.snapshot.phase, FtpChallengePhase.completed);
      expect(c.snapshot.averagePowerW, 100);
    },
  );

  test(
    'zero power is valid and an invalid reading breaks the weighted interval',
    () {
      final zero = FtpChallenge(
        warmupDuration: Duration.zero,
        effortDuration: const Duration(seconds: 2),
      );
      zero.start(t0);
      zero.tick(t0.add(const Duration(seconds: 1)), powerW: 0);
      zero.tick(t0.add(const Duration(seconds: 2)), powerW: 0);
      expect(zero.snapshot.estimatedFtpW, 0);

      final invalid = FtpChallenge(
        warmupDuration: Duration.zero,
        effortDuration: const Duration(seconds: 3),
      );
      invalid.start(t0);
      invalid.tick(t0.add(const Duration(seconds: 1)), powerW: -4);
      invalid.tick(t0.add(const Duration(seconds: 2)), powerW: double.nan);
      invalid.tick(t0.add(const Duration(seconds: 3)), powerW: 200);
      expect(invalid.snapshot.estimatedFtpW, isNull);
    },
  );

  test('completion without a valid effort sample has no FTP estimate', () {
    final c = FtpChallenge(
      warmupDuration: Duration.zero,
      effortDuration: const Duration(seconds: 2),
    );
    c.start(t0);
    c.tick(t0.add(const Duration(seconds: 1)), powerW: null);
    c.tick(t0.add(const Duration(seconds: 2)), powerW: double.infinity);
    expect(c.snapshot.phase, FtpChallengePhase.completed);
    expect(c.snapshot.estimatedFtpW, isNull);
  });

  test('reset replaces a completed assessment with a fresh one', () {
    final c = FtpChallenge(
      warmupDuration: Duration.zero,
      effortDuration: const Duration(seconds: 1),
    );
    c.start(t0);
    // Power is applied on the following tick, so a one-second effort
    // needs a sample before the tick that completes it.
    c.tick(t0.add(const Duration(milliseconds: 500)), powerW: 200);
    c.tick(t0.add(const Duration(seconds: 1)), powerW: 200);
    expect(c.snapshot.phase, FtpChallengePhase.completed);
    expect(c.snapshot.estimatedFtpW, 190);

    c.reset();
    expect(c.snapshot.phase, FtpChallengePhase.idle);
    expect(c.snapshot.estimatedFtpW, isNull);
    expect(c.snapshot.effortElapsed, Duration.zero);
  });
}
