import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Visual effects intensity for Focus mode (P0-V3). Default [off].
enum FocusEffects { off, subtle }

/// Immersive Focus / game-mode ride surface (P0-F1–F4, P0-V*, P0-P2).
///
/// Hides connection chrome / demo / summary / HR / sim. Keeps compact status,
/// mode chip, Disconnect, and optional ERG dock. Glow lives in a
/// [RepaintBoundary] so the 250 ms dashboard poll does not repaint the wash.
class FocusRideView extends StatelessWidget {
  const FocusRideView({
    super.key,
    required this.metrics,
    required this.snap,
    required this.ride,
    required this.targetWatts,
    required this.ergStep,
    required this.connected,
    required this.busy,
    required this.effects,
    required this.onExitFocus,
    required this.onDisconnect,
    required this.onNudge,
    required this.onApplyErg,
    required this.onStepChanged,
    required this.onStopInterval,
    this.intervalRunning = false,
    this.workoutView,
    this.routeChip,
  });

  final TrainerMetrics metrics;
  final ConnectionSnapshot snap;
  final RideStats ride;
  final int targetWatts;
  final int ergStep;
  final bool connected;
  final bool busy;
  final FocusEffects effects;
  final VoidCallback onExitFocus;
  final VoidCallback onDisconnect;
  final ValueChanged<int> onNudge;
  final VoidCallback onApplyErg;
  final ValueChanged<int> onStepChanged;
  final VoidCallback onStopInterval;
  final bool intervalRunning;

  /// Planned-vs-actual workout graph + step strip, shown under the power
  /// hero while a structured workout runs.
  final Widget? workoutView;

  /// "+/- vs best" ghost chip while a GPX route with a stored best runs.
  final Widget? routeChip;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final showWash = effects == FocusEffects.subtle;
    final animate = showWash && !reduceMotion;

    return Material(
      color: RideColors.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showWash)
            Positioned.fill(
              child: RepaintBoundary(
                child: _ZoneWash(
                  watts: metrics.powerW,
                  animated: animate,
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                children: [
                  _FocusChrome(
                    snap: snap,
                    busy: busy,
                    onExitFocus: onExitFocus,
                    onDisconnect: onDisconnect,
                    onStopInterval: onStopInterval,
                    intervalRunning: intervalRunning,
                    routeChip: routeChip,
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 900),
                        // Scales down (never overflows) when a workout
                        // graph shares the screen on 1366×768.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _PowerHero(
                                watts: metrics.powerW,
                                wash: showWash,
                              ),
                              const SizedBox(height: 20),
                              _SecondaryRow(
                                metrics: metrics,
                                pulseCadence: animate,
                              ),
                              const SizedBox(height: 14),
                              _RideRibbon(ride: ride),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (workoutView != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SizedBox(
                        height: (MediaQuery.sizeOf(context).height * 0.36)
                            .clamp(190.0, 360.0),
                        child: workoutView,
                      ),
                    ),
                  _ErgDock(
                    targetWatts: targetWatts,
                    liveTarget: metrics.targetPowerW,
                    step: ergStep,
                    enabled: connected && !busy,
                    dimmed: snap.mode != ControlMode.erg &&
                        snap.mode != ControlMode.idle,
                    onNudge: onNudge,
                    onApply: onApplyErg,
                    onStepChanged: onStepChanged,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Isolated zone wash — only rebuilds when [watts] band changes, not on
/// header/chrome setState from the parent poll.
class _ZoneWash extends StatelessWidget {
  const _ZoneWash({required this.watts, required this.animated});

  final double watts;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final zone = powerZoneAccent(watts);
    final alpha = powerGlowOpacity(watts);
    final decoration = BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(0, -0.2),
        radius: 1.1,
        colors: [
          zone.withValues(alpha: alpha),
          RideColors.bg.withValues(alpha: 0),
        ],
      ),
    );
    if (!animated) {
      return DecoratedBox(decoration: decoration);
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      decoration: decoration,
    );
  }
}

class _FocusChrome extends StatelessWidget {
  const _FocusChrome({
    required this.snap,
    required this.busy,
    required this.onExitFocus,
    required this.onDisconnect,
    required this.onStopInterval,
    required this.intervalRunning,
    this.routeChip,
  });

  final Widget? routeChip;
  final ConnectionSnapshot snap;
  final bool busy;
  final VoidCallback onExitFocus;
  final VoidCallback onDisconnect;
  final VoidCallback onStopInterval;
  final bool intervalRunning;

  @override
  Widget build(BuildContext context) {
    final connected = snap.state == ConnectionState.connected;
    final name = snap.isDemo
        ? 'Demo'
        : (snap.deviceName.isEmpty
            ? (connected ? 'Connected' : 'Disconnected')
            : snap.deviceName);

    return Row(
      children: [
        TextButton.icon(
          key: const ValueKey('focus-exit'),
          onPressed: onExitFocus,
          icon: const Icon(Icons.close_fullscreen, size: 20),
          label: const Text('Exit Focus'),
        ),
        const SizedBox(width: 8),
        Container(
          key: const ValueKey('focus-chip'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: RideColors.accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: RideColors.accent.withValues(alpha: 0.5)),
          ),
          child: const Text(
            'FOCUS',
            style: TextStyle(
              color: RideColors.accent,
              fontWeight: FontWeight.w800,
              fontSize: RideType.caption,
              letterSpacing: 1.1,
            ),
          ),
        ),
        const SizedBox(width: 10),
        _StatusPill(connected: connected || snap.isDemo, label: name),
        const SizedBox(width: 8),
        _ModeChip(mode: snap.mode),
        if (routeChip != null) ...[const SizedBox(width: 8), routeChip!],
        const Spacer(),
        if (intervalRunning)
          TextButton(
            key: const ValueKey('focus-stop-intervals'),
            onPressed: busy ? null : onStopInterval,
            child: const Text('Stop intervals'),
          ),
        const SizedBox(width: 4),
        FilledButton.tonal(
          key: const ValueKey('focus-disconnect'),
          onPressed: busy || (!connected && !snap.isDemo) ? null : onDisconnect,
          style: FilledButton.styleFrom(
            foregroundColor: RideColors.danger,
            minimumSize: const Size(48, kMinTapTarget),
          ),
          child: const Text('Disconnect'),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.connected, required this.label});
  final bool connected;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: RideColors.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: RideColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? RideColors.ok : RideColors.textMuted,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: RideColors.textSecondary,
                fontSize: RideType.label,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});
  final ControlMode mode;

  @override
  Widget build(BuildContext context) {
    final label = switch (mode) {
      ControlMode.erg => 'ERG',
      ControlMode.resistance => 'Res',
      ControlMode.simulation => 'Sim',
      ControlMode.idle => 'Idle',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: RideColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: RideColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: RideColors.textPrimary,
          fontSize: RideType.caption,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PowerHero extends StatelessWidget {
  const _PowerHero({required this.watts, required this.wash});
  final double watts;
  final bool wash;

  @override
  Widget build(BuildContext context) {
    final zone = powerZoneAccent(watts);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: wash ? zone.withValues(alpha: 0.4) : RideColors.border,
        ),
        color: RideColors.surface.withValues(alpha: 0.65),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'POWER',
            style: TextStyle(
              color: wash ? zone : RideColors.power,
              fontSize: RideType.label,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.2,
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              watts.toStringAsFixed(0),
              key: const ValueKey('focus-power'),
              style: const TextStyle(
                fontSize: RideType.gameHero,
                fontWeight: FontWeight.w800,
                height: 1.0,
                letterSpacing: -2,
                color: RideColors.textPrimary,
              ),
            ),
          ),
          const Text(
            'W',
            style: TextStyle(
              fontSize: RideType.title,
              fontWeight: FontWeight.w700,
              color: RideColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SecondaryRow extends StatelessWidget {
  const _SecondaryRow({required this.metrics, required this.pulseCadence});
  final TrainerMetrics metrics;
  final bool pulseCadence;

  @override
  Widget build(BuildContext context) {
    final hr = metrics.heartRateBpm;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CadencePill(
          rpm: metrics.cadenceRpm,
          pulse: pulseCadence && metrics.cadenceRpm > 0,
        ),
        const SizedBox(width: 14),
        _MetricPill(
          label: 'SPEED',
          value: metrics.speedKmh.toStringAsFixed(1),
          unit: 'km/h',
          color: RideColors.speed,
        ),
        if (hr != null) ...[
          const SizedBox(width: 14),
          _MetricPill(
            label: 'HR',
            value: '$hr',
            unit: 'bpm',
            color: RideColors.heart,
          ),
        ],
      ],
    );
  }
}

/// Optional tiny cadence pulse (≤2% scale, ≤2 Hz) — P0-V2.
class _CadencePill extends StatefulWidget {
  const _CadencePill({required this.rpm, required this.pulse});
  final double rpm;
  final bool pulse;

  @override
  State<_CadencePill> createState() => _CadencePillState();
}

class _CadencePillState extends State<_CadencePill>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _CadencePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse != widget.pulse || oldWidget.rpm != widget.rpm) {
      _sync();
    }
  }

  void _sync() {
    if (!widget.pulse) {
      _ctrl?.stop();
      return;
    }
    _ctrl ??= AnimationController(vsync: this);
    // Cap visual at 2 Hz (period ≥ 500ms) — epilepsy-safe.
    final hz = (widget.rpm / 60.0).clamp(0.4, 2.0);
    _ctrl!.duration = Duration(milliseconds: (1000 / hz).round());
    if (!_ctrl!.isAnimating) {
      _ctrl!.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _MetricPill(
      label: 'CADENCE',
      value: widget.rpm.toStringAsFixed(0),
      unit: 'rpm',
      color: RideColors.cadence,
    );
    final c = _ctrl;
    if (!widget.pulse || c == null) return child;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(c.value);
          final scale = 1.0 + 0.02 * t;
          return Transform.scale(scale: scale, child: child);
        },
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
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
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: RideColors.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: RideType.footnote,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: const TextStyle(
                    fontSize: RideType.focusMetric,
                    fontWeight: FontWeight.w800,
                    color: RideColors.textPrimary,
                    height: 1.05,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: const TextStyle(
                    fontSize: RideType.caption,
                    color: RideColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RideRibbon extends StatelessWidget {
  const _RideRibbon({required this.ride});
  final RideStats ride;

  @override
  Widget build(BuildContext context) {
    final elapsed = _fmt(ride.elapsedS);
    return Opacity(
      opacity: 0.8,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        children: [
          Text(elapsed, style: _style),
          if (ride.avgPowerW > 0)
            Text(
              'avg ${ride.avgPowerW.toStringAsFixed(0)} W',
              style: _style,
            ),
          if (ride.energyKj > 0)
            Text(
              '${ride.energyKj.toStringAsFixed(0)} kJ',
              style: _style,
            ),
        ],
      ),
    );
  }

  static const _style = TextStyle(
    color: RideColors.textMuted,
    fontSize: RideType.label,
    fontWeight: FontWeight.w600,
  );

  static String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class _ErgDock extends StatelessWidget {
  const _ErgDock({
    required this.targetWatts,
    required this.liveTarget,
    required this.step,
    required this.enabled,
    required this.dimmed,
    required this.onNudge,
    required this.onApply,
    required this.onStepChanged,
  });

  final int targetWatts;
  final double? liveTarget;
  final int step;
  final bool enabled;
  final bool dimmed;
  final ValueChanged<int> onNudge;
  final VoidCallback onApply;
  final ValueChanged<int> onStepChanged;

  @override
  Widget build(BuildContext context) {
    final live = liveTarget?.round();
    final pending = live != null && live != targetWatts;
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Container(
        key: const ValueKey('focus-erg-dock'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: RideColors.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: RideColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text(
                  'ERG',
                  style: TextStyle(
                    color: RideColors.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: RideType.label,
                  ),
                ),
                const Spacer(),
                Text(
                  '$targetWatts W',
                  style: const TextStyle(
                    fontSize: RideType.title,
                    fontWeight: FontWeight.w800,
                    color: RideColors.textPrimary,
                  ),
                ),
                if (pending) ...[
                  const SizedBox(width: 8),
                  Text(
                    '→ ${live}W',
                    style: const TextStyle(
                      color: RideColors.warn,
                      fontSize: RideType.caption,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 44,
                  child: FilledButton(
                    key: const ValueKey('focus-erg-minus'),
                    style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: enabled ? () => onNudge(-1) : null,
                    child: const Text('−', style: TextStyle(fontSize: RideType.glyph)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: enabled ? onApply : null,
                    child: const Text('Apply'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  height: 44,
                  child: FilledButton(
                    key: const ValueKey('focus-erg-plus'),
                    style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: enabled ? () => onNudge(1) : null,
                    child: const Text('+', style: TextStyle(fontSize: RideType.glyph)),
                  ),
                ),
                const SizedBox(width: 12),
                for (final s in [5, 10, 25])
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ChoiceChip(
                      label: Text('±$s'),
                      selected: step == s,
                      onSelected: enabled ? (_) => onStepChanged(s) : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Align(
              alignment: Alignment.centerRight,
              child: Text(
                'G Focus · F11 fullscreen · Esc exits fullscreen',
                style: TextStyle(
                  color: RideColors.textMuted,
                  fontSize: RideType.footnote,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
