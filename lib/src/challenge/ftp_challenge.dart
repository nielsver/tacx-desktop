enum FtpChallengePhase {
  idle,
  warmup,
  effort,
  pausedWarmup,
  pausedEffort,
  completed,
  ended,
  interrupted,
}

class FtpChallengeSnapshot {
  const FtpChallengeSnapshot({
    required this.phase,
    required this.phaseElapsed,
    required this.phaseRemaining,
    required this.effortElapsed,
    required this.averagePowerW,
    required this.estimatedFtpW,
    required this.statusLabel,
  });

  final FtpChallengePhase phase;
  final Duration phaseElapsed;
  final Duration phaseRemaining;
  final Duration effortElapsed;
  final double? averagePowerW;
  final int? estimatedFtpW;
  final String statusLabel;
}

/// In-memory warm-up + free-ride assessment, with pause-safe elapsed time.
class FtpChallenge {
  FtpChallenge({
    this.warmupDuration = const Duration(minutes: 10),
    this.effortDuration = const Duration(minutes: 20),
  }) : assert(!warmupDuration.isNegative),
       assert(!effortDuration.isNegative);

  final Duration warmupDuration;
  final Duration effortDuration;

  FtpChallengePhase _phase = FtpChallengePhase.idle;
  FtpChallengePhase? _resumePhase;
  DateTime? _lastTickAt;
  Duration _warmupElapsed = Duration.zero;
  Duration _effortElapsed = Duration.zero;
  double? _previousPowerW;
  double _weightedPowerSeconds = 0;
  double _coveredSeconds = 0;
  int? _estimatedFtpW;

  FtpChallengePhase get phase => _phase;
  FtpChallengeSnapshot get snapshot => _snapshot();

  void reset() {
    _phase = FtpChallengePhase.idle;
    _resumePhase = null;
    _lastTickAt = null;
    _warmupElapsed = Duration.zero;
    _effortElapsed = Duration.zero;
    _previousPowerW = null;
    _weightedPowerSeconds = 0;
    _coveredSeconds = 0;
    _estimatedFtpW = null;
  }

  void start(DateTime now) {
    if (_phase != FtpChallengePhase.idle) return;
    _lastTickAt = now;
    _phase = warmupDuration == Duration.zero
        ? FtpChallengePhase.effort
        : FtpChallengePhase.warmup;
  }

  void tick(DateTime now, {required double? powerW}) {
    if (_phase != FtpChallengePhase.warmup &&
        _phase != FtpChallengePhase.effort) {
      return;
    }
    _advance(now);
    if (_phase == FtpChallengePhase.effort) {
      _previousPowerW = _isValidPower(powerW) ? powerW : null;
    }
    _lastTickAt = now;
  }

  void pause(DateTime now) {
    if (_phase != FtpChallengePhase.warmup &&
        _phase != FtpChallengePhase.effort) {
      return;
    }
    _advance(now);
    if (_phase != FtpChallengePhase.warmup &&
        _phase != FtpChallengePhase.effort) {
      return;
    }
    _phase = _phase == FtpChallengePhase.warmup
        ? FtpChallengePhase.pausedWarmup
        : FtpChallengePhase.pausedEffort;
    _previousPowerW = null;
    _lastTickAt = now;
  }

  void interrupt(DateTime now) {
    if (_phase != FtpChallengePhase.warmup &&
        _phase != FtpChallengePhase.effort) {
      return;
    }
    _advance(now);
    if (_phase != FtpChallengePhase.warmup &&
        _phase != FtpChallengePhase.effort) {
      return;
    }
    _resumePhase = _phase;
    _phase = FtpChallengePhase.interrupted;
    _previousPowerW = null;
    _lastTickAt = now;
  }

  void resume(DateTime now) {
    if (_phase == FtpChallengePhase.pausedWarmup) {
      _phase = FtpChallengePhase.warmup;
    } else if (_phase == FtpChallengePhase.pausedEffort) {
      _phase = FtpChallengePhase.effort;
    } else if (_phase == FtpChallengePhase.interrupted &&
        _resumePhase != null) {
      _phase = _resumePhase!;
      _resumePhase = null;
    } else {
      return;
    }
    _previousPowerW = null;
    _lastTickAt = now;
  }

  void end(DateTime now) {
    if (_phase == FtpChallengePhase.warmup ||
        _phase == FtpChallengePhase.effort) {
      _advance(now);
      if (_phase != FtpChallengePhase.completed) {
        _phase = FtpChallengePhase.ended;
      }
    } else if (_phase == FtpChallengePhase.pausedWarmup ||
        _phase == FtpChallengePhase.pausedEffort ||
        _phase == FtpChallengePhase.interrupted) {
      _phase = FtpChallengePhase.ended;
    }
    _previousPowerW = null;
  }

  void _advance(DateTime now) {
    final previous = _lastTickAt;
    if (previous == null || !now.isAfter(previous)) return;
    var remaining = now.difference(previous);
    if (_phase == FtpChallengePhase.warmup) {
      final untilEffort = warmupDuration - _warmupElapsed;
      final warmupPart = remaining < untilEffort ? remaining : untilEffort;
      _warmupElapsed += warmupPart;
      remaining -= warmupPart;
      if (_warmupElapsed >= warmupDuration) {
        _phase = FtpChallengePhase.effort;
        _previousPowerW = null;
      }
    }
    if (_phase == FtpChallengePhase.effort && remaining > Duration.zero) {
      final untilComplete = effortDuration - _effortElapsed;
      final effortPart = remaining < untilComplete ? remaining : untilComplete;
      final seconds =
          effortPart.inMicroseconds / Duration.microsecondsPerSecond;
      final previousPower = _previousPowerW;
      if (previousPower != null && _isValidPower(previousPower)) {
        _weightedPowerSeconds += previousPower * seconds;
        _coveredSeconds += seconds;
      }
      _effortElapsed += effortPart;
      if (_effortElapsed >= effortDuration) {
        _phase = FtpChallengePhase.completed;
        if (_coveredSeconds > 0) {
          _estimatedFtpW = (0.95 * _weightedPowerSeconds / _coveredSeconds)
              .round();
        }
        _previousPowerW = null;
      }
    }
  }

  FtpChallengeSnapshot _snapshot() {
    final displayedPhase = _phase == FtpChallengePhase.interrupted
        ? _resumePhase
        : _phase;
    final isWarmup =
        displayedPhase == FtpChallengePhase.warmup ||
        displayedPhase == FtpChallengePhase.pausedWarmup;
    final isEffort =
        displayedPhase == FtpChallengePhase.effort ||
        displayedPhase == FtpChallengePhase.pausedEffort;
    final phaseElapsed = isWarmup ? _warmupElapsed : _effortElapsed;
    final duration = isWarmup
        ? warmupDuration
        : (isEffort ? effortDuration : Duration.zero);
    return FtpChallengeSnapshot(
      phase: _phase,
      phaseElapsed: phaseElapsed,
      phaseRemaining: duration > phaseElapsed
          ? duration - phaseElapsed
          : Duration.zero,
      effortElapsed: _effortElapsed,
      averagePowerW: _coveredSeconds > 0
          ? _weightedPowerSeconds / _coveredSeconds
          : null,
      estimatedFtpW: _phase == FtpChallengePhase.completed
          ? _estimatedFtpW
          : null,
      statusLabel: switch (_phase) {
        FtpChallengePhase.idle => 'Ready when you are',
        FtpChallengePhase.warmup => 'Warm up',
        FtpChallengePhase.effort => '20-minute effort',
        FtpChallengePhase.pausedWarmup ||
        FtpChallengePhase.pausedEffort => 'Paused',
        FtpChallengePhase.completed => 'Challenge complete',
        FtpChallengePhase.ended => 'Challenge ended',
        FtpChallengePhase.interrupted =>
          'Trainer disconnected · reconnect to resume',
      },
    );
  }

  bool _isValidPower(double? watts) =>
      watts != null && watts.isFinite && watts >= 0;
}
