import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/challenge/ftp_challenge.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/trainer/types.dart';

class FtpChallengeScreen extends StatefulWidget {
  const FtpChallengeScreen({
    super.key,
    required this.challenge,
    this.onAcceptFtp,
  });

  final FtpChallenge challenge;
  final Future<bool> Function(int ftpW)? onAcceptFtp;

  @override
  State<FtpChallengeScreen> createState() => _FtpChallengeScreenState();
}

class _FtpChallengeScreenState extends State<FtpChallengeScreen> {
  FtpChallenge get _challenge => widget.challenge;
  Timer? _timer;
  TrainerMetrics _metrics = const TrainerMetrics(
    powerW: 0,
    cadenceRpm: 0,
    speedKmh: 0,
  );
  ConnectionSnapshot _trainer = const ConnectionSnapshot(
    state: ConnectionState.disconnected,
    detail: '',
    protocol: ProtocolKind.ftms,
    isDemo: false,
    mode: ControlMode.idle,
    deviceName: '',
    supportsSimulation: false,
    reconnectAttempt: 0,
    reconnectMaxAttempts: 0,
    reconnectInS: 0,
    reconnectGaveUp: false,
  );
  HrStrapStatus _heartRate = const HrStrapStatus(
    state: HrStrapState.disconnected,
    deviceId: '',
    deviceName: '',
    detail: 'No heart-rate strap connected',
  );
  bool _lastTrainerConnected = false;
  bool _preparing = false;
  bool _reconnecting = false;
  bool _acceptingFtp = false;
  bool _ftpAccepted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _trainerConnected => _trainer.state == ConnectionState.connected;

  void _refresh() {
    if (!mounted) return;
    final now = DateTime.now();
    final trainer = api.getConnectionSnapshot();
    final metrics = api.getMetrics();
    final connected = trainer.state == ConnectionState.connected;
    final current = _challenge.phase;
    if (!connected &&
        _lastTrainerConnected &&
        (current == FtpChallengePhase.warmup ||
            current == FtpChallengePhase.effort)) {
      _challenge.interrupt(now);
    } else if (connected &&
        (current == FtpChallengePhase.warmup ||
            current == FtpChallengePhase.effort)) {
      _challenge.tick(
        now,
        powerW: current == FtpChallengePhase.effort ? metrics.powerW : null,
      );
    }
    _lastTrainerConnected = connected;
    setState(() {
      _trainer = trainer;
      _metrics = metrics;
    });
    _refreshHeartRate();
  }

  void _refreshHeartRate() {
    try {
      final snapshot = api.getHeartRateStrapStatus();
      if (mounted) setState(() => _heartRate = snapshot);
    } catch (_) {
      // Keep the last sensor reading while Bluetooth is transitioning.
    }
  }

  Future<void> _start() async {
    if (!_trainerConnected || _preparing) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      api.stopInterval();
      api.stopWorkout();
      api.stopGpxRoute();
      await api.setResistancePercent(percent: 0);
      if (!mounted) return;
      _challenge.start(DateTime.now());
      _lastTrainerConnected = true;
      _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _reconnectTrainer() async {
    if (_reconnecting) return;
    setState(() {
      _reconnecting = true;
      _error = null;
    });
    try {
      await api.reconnectTrainer();
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  void _pause() {
    _challenge.pause(DateTime.now());
    _refresh();
  }

  void _resume() {
    if (!_trainerConnected) return;
    _challenge.resume(DateTime.now());
    _lastTrainerConnected = true;
    _refresh();
  }

  void _end() {
    _challenge.end(DateTime.now());
    _refresh();
  }

  void _reset() {
    _challenge.reset();
    _ftpAccepted = false;
    _refresh();
  }

  Future<void> _acceptFtp(int ftpW) async {
    final onAcceptFtp = widget.onAcceptFtp;
    if (onAcceptFtp == null || _acceptingFtp || _ftpAccepted) return;
    setState(() => _acceptingFtp = true);
    try {
      final accepted = await onAcceptFtp(ftpW);
      if (accepted && mounted) setState(() => _ftpAccepted = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _acceptingFtp = false);
    }
  }

  void _endAndLeave() {
    _challenge.end(DateTime.now());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge.snapshot;
    final phase = challenge.phase;
    final running =
        phase == FtpChallengePhase.warmup || phase == FtpChallengePhase.effort;
    final paused =
        phase == FtpChallengePhase.pausedWarmup ||
        phase == FtpChallengePhase.pausedEffort;
    final interrupted = phase == FtpChallengePhase.interrupted;
    final complete = phase == FtpChallengePhase.completed;
    final sessionActive = running || paused || interrupted;
    final strapConnected =
        _heartRate.state == HrStrapState.connected &&
        _heartRate.heartRateBpm != null;
    final heartRateBpm = strapConnected
        ? _heartRate.heartRateBpm
        : _metrics.heartRateBpm;
    final hasFreshHeartRate = heartRateBpm != null;
    final demo = _trainer.isDemo;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return PopScope(
      canPop: !sessionActive,
      child: Scaffold(
        appBar: AppBar(
          leading: sessionActive
              ? IconButton(
                  tooltip: 'End challenge and return',
                  onPressed: _endAndLeave,
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: const Text('FTP assessment'),
          backgroundColor: theme.scaffoldBackgroundColor,
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                children: [
                  if (demo) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFC857).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFFFC857).withValues(alpha: 0.45),
                        ),
                      ),
                      child: const Text(
                        'DEMO MODE · Simulated training data',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFFFC857),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    switch (phase) {
                      FtpChallengePhase.idle => 'Find your steady effort',
                      FtpChallengePhase.warmup ||
                      FtpChallengePhase.pausedWarmup => 'Settle into the ride',
                      FtpChallengePhase.effort ||
                      FtpChallengePhase.pausedEffort =>
                        'Hold your best 20-minute pace',
                      FtpChallengePhase.completed =>
                        'Assessment complete for this session',
                      FtpChallengePhase.ended => 'Assessment ended',
                      FtpChallengePhase.interrupted =>
                        'Trainer link interrupted',
                    },
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '10-minute warm-up, then 20 minutes at your strongest steady pace. '
                    'Estimated FTP uses 95% of your average effort power.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _ChallengeClock(
                    phase: phase,
                    elapsed: challenge.phaseElapsed,
                    remaining: challenge.phaseRemaining,
                    warmupDuration: const Duration(minutes: 10),
                    effortDuration: const Duration(minutes: 20),
                    accent: accent,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _LiveValue(
                          label: 'Power',
                          value: _metrics.powerW.toStringAsFixed(0),
                          unit: 'W',
                          color: const Color(0xFFFFA35C),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _LiveValue(
                          label: 'Heart rate',
                          value: hasFreshHeartRate ? '$heartRateBpm' : '—',
                          unit: hasFreshHeartRate ? 'bpm' : 'optional',
                          color: const Color(0xFFFF7189),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _LiveValue(
                          label: 'Cadence',
                          value: _metrics.cadenceRpm.toStringAsFixed(0),
                          unit: 'rpm',
                          color: const Color(0xFF70D9BC),
                        ),
                      ),
                    ],
                  ),
                  if (!strapConnected && !complete) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Heart rate is optional${_heartRate.detail.isEmpty ? '' : ' · ${_heartRate.detail}'}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white54,
                      ),
                    ),
                  ],
                  if (challenge.averagePowerW != null && running) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Effort average ${challenge.averagePowerW!.toStringAsFixed(0)} W',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                  if (complete && challenge.estimatedFtpW != null) ...[
                    const SizedBox(height: 20),
                    _ResultCard(
                      snapshot: challenge,
                      isDemo: demo,
                      accepted: _ftpAccepted,
                      accepting: _acceptingFtp,
                      onAccept: widget.onAcceptFtp == null || demo
                          ? null
                          : () => _acceptFtp(challenge.estimatedFtpW!),
                    ),
                  ],
                  if (complete && challenge.estimatedFtpW == null) ...[
                    const SizedBox(height: 18),
                    const Center(
                      child: Text(
                        'No FTP estimate: no valid power data was recorded.',
                      ),
                    ),
                  ],
                  if (phase == FtpChallengePhase.ended) ...[
                    const SizedBox(height: 18),
                    const Center(
                      child: Text(
                        'No FTP estimate was created because the effort ended early.',
                      ),
                    ),
                  ],
                  if (interrupted) ...[
                    const SizedBox(height: 18),
                    Center(
                      child: Text(
                        _trainerConnected
                            ? 'Trainer reconnected. Resume when you are ready.'
                            : 'Reconnect the trainer from the dashboard, then resume this phase.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 22),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (phase == FtpChallengePhase.idle)
                        FilledButton.icon(
                          onPressed: _trainerConnected && !_preparing
                              ? _start
                              : null,
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                            _preparing ? 'Preparing trainer…' : 'Start warm-up',
                          ),
                        ),
                      if (running)
                        FilledButton.tonalIcon(
                          onPressed: _pause,
                          icon: const Icon(Icons.pause),
                          label: const Text('Pause'),
                        ),
                      if (paused && !_trainerConnected)
                        FilledButton.tonalIcon(
                          onPressed: _reconnecting ? null : _reconnectTrainer,
                          icon: const Icon(Icons.bluetooth_searching),
                          label: Text(
                            _reconnecting
                                ? 'Reconnecting…'
                                : 'Reconnect trainer',
                          ),
                        ),
                      if (paused)
                        FilledButton.icon(
                          onPressed: _trainerConnected ? _resume : null,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Resume'),
                        ),
                      if (interrupted)
                        if (!_trainerConnected)
                          FilledButton.tonalIcon(
                            onPressed: _reconnecting ? null : _reconnectTrainer,
                            icon: const Icon(Icons.bluetooth_searching),
                            label: Text(
                              _reconnecting
                                  ? 'Reconnecting…'
                                  : 'Reconnect trainer',
                            ),
                          )
                        else
                          FilledButton.icon(
                            onPressed: _resume,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Resume challenge'),
                          ),
                      if (running || paused || interrupted)
                        OutlinedButton.icon(
                          onPressed: _end,
                          icon: const Icon(Icons.stop),
                          label: const Text('End challenge'),
                        ),
                      if (complete || phase == FtpChallengePhase.ended)
                        OutlinedButton.icon(
                          onPressed: _reset,
                          icon: const Icon(Icons.refresh),
                          label: const Text('New assessment'),
                        ),
                      if (!_trainerConnected && phase == FtpChallengePhase.idle)
                        Text(
                          'Connect a trainer from the dashboard to begin.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white54,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    challenge.statusLabel,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white54,
                    ),
                  ),
                  if (sessionActive) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'End the challenge before returning to trainer controls.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChallengeClock extends StatelessWidget {
  const _ChallengeClock({
    required this.phase,
    required this.elapsed,
    required this.remaining,
    required this.warmupDuration,
    required this.effortDuration,
    required this.accent,
  });

  final FtpChallengePhase phase;
  final Duration elapsed;
  final Duration remaining;
  final Duration warmupDuration;
  final Duration effortDuration;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final warmup =
        phase == FtpChallengePhase.warmup ||
        phase == FtpChallengePhase.pausedWarmup;
    final timed =
        warmup ||
        phase == FtpChallengePhase.effort ||
        phase == FtpChallengePhase.pausedEffort;
    final total = warmup ? warmupDuration : effortDuration;
    final progress = timed && total > Duration.zero
        ? (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final color =
        phase == FtpChallengePhase.effort ||
            phase == FtpChallengePhase.pausedEffort
        ? const Color(0xFF73D8B0)
        : accent;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF151A22),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Text(
            switch (phase) {
              FtpChallengePhase.idle => 'READY',
              FtpChallengePhase.warmup ||
              FtpChallengePhase.pausedWarmup => 'WARM-UP',
              FtpChallengePhase.effort ||
              FtpChallengePhase.pausedEffort => '20-MINUTE EFFORT',
              FtpChallengePhase.completed => 'COMPLETE',
              FtpChallengePhase.ended => 'ENDED',
              FtpChallengePhase.interrupted => 'INTERRUPTED',
            },
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            timed ? _formatDuration(remaining) : '30:00',
            style: const TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.w700,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.white12,
              color: color,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            warmup
                ? 'Keep it light and let your legs come around.'
                : phase == FtpChallengePhase.effort ||
                      phase == FtpChallengePhase.pausedEffort
                ? 'Ride hard, smooth, and steady. No targets will change.'
                : '10 min warm-up  /  20 min free ride',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _LiveValue extends StatelessWidget {
  const _LiveValue({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF151A22),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
          ),
        ),
        Text(unit, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    ),
  );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.snapshot,
    required this.isDemo,
    required this.accepted,
    required this.accepting,
    required this.onAccept,
  });

  final FtpChallengeSnapshot snapshot;
  final bool isDemo;
  final bool accepted;
  final bool accepting;
  final VoidCallback? onAccept;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: const Color(0xFF17342F),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(
        color: const Color(0xFF70D9BC).withValues(alpha: 0.45),
      ),
    ),
    child: Column(
      children: [
        Text(
          isDemo ? 'Demo FTP estimate' : 'Estimated FTP',
          style: const TextStyle(color: Color(0xFF9DE8D2)),
        ),
        const SizedBox(height: 4),
        Text(
          snapshot.estimatedFtpW == null ? '—' : '${snapshot.estimatedFtpW} W',
          style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800),
        ),
        if (snapshot.averagePowerW != null)
          Text(
            '20-minute average ${snapshot.averagePowerW!.toStringAsFixed(0)} W · 20-minute effort',
            style: const TextStyle(color: Colors.white70),
          ),
        if (isDemo)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Demo results cannot be saved to your FTP profile.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
          )
        else if (onAccept != null || accepted)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: FilledButton.tonalIcon(
              onPressed: accepting || accepted ? null : onAccept,
              icon: Icon(accepted ? Icons.check : Icons.save_outlined),
              label: Text(
                accepted
                    ? 'FTP saved to training profile'
                    : accepting
                    ? 'Saving FTP…'
                    : 'Use this FTP for training zones',
              ),
            ),
          ),
      ],
    ),
  );
}

String _formatDuration(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
  final minutesPart = (seconds ~/ 60).toString().padLeft(2, '0');
  final secondsPart = (seconds % 60).toString().padLeft(2, '0');
  return '$minutesPart:$secondsPart';
}
