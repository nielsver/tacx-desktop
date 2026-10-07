import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

const _tabular = [FontFeature.tabularFigures()];

/// Live position in a running (or just finished) workout, derived from the
/// engine's `WorkoutStatus` (step index + time left in the step).
@immutable
class WorkoutProgress {
  const WorkoutProgress({
    required this.stepIndex,
    required this.remainingS,
    this.running = true,
    this.done = false,
  });

  final int stepIndex;
  final double remainingS;
  final bool running;
  final bool done;
}

/// Planned-vs-actual workout view (Pro M1): a step strip (current target,
/// time left, next step, 3-2-1 countdown) above a graph of zone-coloured
/// planned blocks, the actual power line and a "now" cursor.
class WorkoutRideView extends StatelessWidget {
  const WorkoutRideView({
    super.key,
    required this.plan,
    required this.progress,
    required this.trace,
    required this.ftp,
    this.livePowerW,
    this.onEditFtp,
    this.large = false,
  });

  final WorkoutPlan plan;
  final WorkoutProgress progress;
  final WorkoutTrace trace;
  final int ftp;
  final double? livePowerW;
  final VoidCallback? onEditFtp;

  /// Focus / fullscreen sizing (bigger step strip numbers).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final elapsed = plan.elapsedFrom(
      stepIndex: progress.stepIndex,
      remainingS: progress.remainingS,
      done: progress.done,
    );
    return Container(
      key: const ValueKey('workout-ride-view'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: RideColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RideColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntervalTimeline(
            plan: plan,
            progress: progress,
            ftp: ftp,
            elapsedS: elapsed,
            large: large,
            onEditFtp: onEditFtp,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RepaintBoundary(
              child: ListenableBuilder(
                listenable: trace,
                builder: (context, _) => CustomPaint(
                  key: const ValueKey('workout-graph'),
                  painter: WorkoutGraphPainter(
                    plan: plan,
                    ftp: ftp,
                    elapsedS: elapsed,
                    actual: trace.workoutId == plan.id
                        ? trace.points
                        : const [],
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Current / next step strip with a 3-2-1 countdown before step changes.
class IntervalTimeline extends StatelessWidget {
  const IntervalTimeline({
    super.key,
    required this.plan,
    required this.progress,
    required this.ftp,
    required this.elapsedS,
    this.large = false,
    this.onEditFtp,
  });

  final WorkoutPlan plan;
  final WorkoutProgress progress;
  final int ftp;
  final double elapsedS;
  final bool large;
  final VoidCallback? onEditFtp;

  @override
  Widget build(BuildContext context) {
    if (plan.steps.isEmpty) {
      return const Text('Workout has no steps');
    }
    final i = progress.stepIndex.clamp(0, plan.steps.length - 1);
    final step = plan.steps[i];
    final hasNext = i + 1 < plan.steps.length;
    final next = hasNext ? plan.steps[i + 1] : null;
    final inStep = (elapsedS - plan.startOf(i)).clamp(
      0.0,
      step.durationS * 1.0,
    );
    final target = step.targetAt(inStep);
    final color = _stepColor(step, target, ftp);
    final count = progress.running && !progress.done
        ? stepCountdown(progress.remainingS, hasNext: hasNext)
        : null;
    final stepFrac = progress.done
        ? 1.0
        : (inStep / math.max(1, step.durationS)).clamp(0.0, 1.0);
    final bigSize = large ? RideType.target : RideType.header;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final current = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          progress.done
              ? 'WORKOUT DONE'
              : 'STEP ${i + 1}/${plan.steps.length} · ${_kindLabel(step)}',
          style: const TextStyle(
            color: RideColors.textSecondary,
            fontSize: RideType.caption,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              progress.done ? plan.name : _targetText(step, target),
              key: const ValueKey('workout-current-target'),
              style: TextStyle(
                color: RideColors.textPrimary,
                fontSize: bigSize,
                fontWeight: FontWeight.w800,
                fontFeatures: _tabular,
                height: 1.1,
              ),
            ),
            if (!progress.done && target != null) ...[
              const SizedBox(width: 8),
              Text(
                'Z${powerZone(target, ftp)} · ${(target / math.max(1, ftp) * 100).round()} %',
                style: TextStyle(
                  color: color,
                  fontSize: RideType.label,
                  fontWeight: FontWeight.w700,
                  fontFeatures: _tabular,
                ),
              ),
            ],
          ],
        ),
      ],
    );

    final timeLeft = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'STEP LEFT',
          style: TextStyle(
            color: RideColors.textSecondary,
            fontSize: RideType.caption,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        Text(
          progress.done ? '0:00' : fmtClock(progress.remainingS.ceil()),
          key: const ValueKey('workout-step-left'),
          style: TextStyle(
            color: RideColors.textPrimary,
            fontSize: bigSize,
            fontWeight: FontWeight.w800,
            fontFeatures: _tabular,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: large ? 160 : 120,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const ValueKey('workout-step-progress'),
              value: stepFrac,
              minHeight: 4,
              color: color,
              backgroundColor: RideColors.border,
            ),
          ),
        ),
      ],
    );

    final nextCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'NEXT',
          style: TextStyle(
            color: RideColors.textSecondary,
            fontSize: RideType.caption,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (next != null) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _stepColor(next, next.targetAt(0), ftp),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              next == null
                  ? (progress.done ? '—' : 'Finish')
                  : '${fmtClock(next.durationS)} @ ${next.targetLabel}',
              key: const ValueKey('workout-next-step'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: RideColors.textPrimary,
                fontSize: large ? RideType.metric : RideType.title,
                fontWeight: FontWeight.w700,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ],
    );

    final total = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            plan.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: RideColors.textSecondary,
              fontSize: RideType.caption,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '${fmtClock(elapsedS)} / ${fmtClock(plan.totalS)}',
          key: const ValueKey('workout-total-clock'),
          style: const TextStyle(
            color: RideColors.textPrimary,
            fontSize: RideType.body,
            fontWeight: FontWeight.w700,
            fontFeatures: _tabular,
          ),
        ),
        if (onEditFtp != null)
          TextButton(
            key: const ValueKey('workout-ftp'),
            onPressed: onEditFtp,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: RideColors.textSecondary,
            ),
            child: Text(
              'FTP $ftp W',
              style: const TextStyle(
                fontSize: RideType.caption,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        else
          Text(
            'FTP $ftp W',
            style: const TextStyle(
              color: RideColors.textMuted,
              fontSize: RideType.caption,
            ),
          ),
      ],
    );

    final countdownColor = next == null
        ? RideColors.accent
        : _stepColor(next, next.targetAt(0), ftp);
    final badge = SizedBox(
      width: large ? 64 : 48,
      height: large ? 64 : 48,
      child: count == null
          ? null
          : _CountdownBadge(
              key: ValueKey('workout-countdown-$count'),
              value: count,
              color: countdownColor,
              large: large,
            ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 4, child: _fitStart(current)),
        const SizedBox(width: 12),
        _fitStart(timeLeft),
        const SizedBox(width: 12),
        reduceMotion
            ? badge
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(
                    scale: Tween(begin: 0.85, end: 1.0).animate(a),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey('cd-${count ?? 0}'),
                  child: badge,
                ),
              ),
        const SizedBox(width: 12),
        Expanded(flex: 4, child: _fitStart(nextCol)),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: total,
          ),
        ),
      ],
    );
  }

  /// Shrinks (never overflows) on narrow windows; natural size otherwise.
  static Widget _fitStart(Widget child) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: child,
  );

  static String _kindLabel(PlanStep s) => switch (s.kind) {
    'erg' => 'ERG',
    'ramp' => 'RAMP',
    'simGrade' => 'SIM',
    'resistance' => 'RES',
    _ => s.kind.toUpperCase(),
  };

  static String _targetText(PlanStep s, double? target) {
    if (target != null) return '${target.round()} W';
    return s.targetLabel;
  }
}

Color _stepColor(PlanStep s, double? target, int ftp) =>
    target == null ? kNonPowerStepColor : zoneColor(powerZone(target, ftp));

class _CountdownBadge extends StatelessWidget {
  const _CountdownBadge({
    super.key,
    required this.value,
    required this.color,
    required this.large,
  });

  final int value;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Next step in $value',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.18),
          border: Border.all(color: color, width: 2),
        ),
        child: Center(
          child: Text(
            '$value',
            style: TextStyle(
              color: RideColors.textPrimary,
              fontSize: large ? RideType.glyph : RideType.header,
              fontWeight: FontWeight.w800,
              fontFeatures: _tabular,
            ),
          ),
        ),
      ),
    );
  }
}

/// Geometry of one planned block in graph space (top edge may slope: ramps).
@immutable
class PlanBlockGeom {
  const PlanBlockGeom({
    required this.index,
    required this.x0,
    required this.x1,
    required this.yTop0,
    required this.yTop1,
    required this.color,
  });

  final int index;
  final double x0;
  final double x1;
  final double yTop0;
  final double yTop1;
  final Color color;

  double get width => x1 - x0;
}

/// Pure layout maths for [WorkoutGraphPainter] (unit-tested).
abstract final class WorkoutGraphLayout {
  /// Watts mapped to the top of the plot. Leaves headroom above the plan
  /// (and FTP) and follows actual power up to a sane cap.
  static double yMax(WorkoutPlan plan, int ftp, {double actualMax = 0}) {
    final base = math.max(plan.maxWatts, ftp).toDouble();
    final capped = math.min(actualMax, base * 1.6);
    return math.max(100.0, math.max(base, capped) * 1.15);
  }

  /// Height fraction (0..1 of the plot) for steps without a watt target.
  static double nonPowerHeight(PlanStep s) {
    if (s.kind == 'simGrade') {
      return (((s.gradePct ?? 0) + 2) / 12).clamp(0.08, 0.9);
    }
    if (s.kind == 'resistance') {
      return ((s.resistancePct ?? 20) / 100 * 0.9).clamp(0.08, 0.9);
    }
    return 0.15;
  }

  /// One block per step: width ∝ duration, height ∝ target watts.
  static List<PlanBlockGeom> blocks(
    WorkoutPlan plan,
    Size size,
    int ftp, {
    double? yMaxW,
  }) {
    final total = math.max(1, plan.totalS);
    final ym = yMaxW ?? yMax(plan, ftp);
    double y(double w) => size.height * (1 - (w / ym).clamp(0.0, 1.0));
    final out = <PlanBlockGeom>[];
    for (var i = 0; i < plan.steps.length; i++) {
      final s = plan.steps[i];
      final x0 = plan.startOf(i) / total * size.width;
      final x1 = plan.startOf(i + 1) / total * size.width;
      if (s.hasPower) {
        final a = s.startW!.toDouble();
        final b = (s.endW ?? s.startW!).toDouble();
        final mid = (a + b) / 2;
        out.add(
          PlanBlockGeom(
            index: i,
            x0: x0,
            x1: x1,
            yTop0: y(a),
            yTop1: y(b),
            color: zoneColor(powerZone(mid, ftp)),
          ),
        );
      } else {
        final top = size.height * (1 - nonPowerHeight(s));
        out.add(
          PlanBlockGeom(
            index: i,
            x0: x0,
            x1: x1,
            yTop0: top,
            yTop1: top,
            color: kNonPowerStepColor,
          ),
        );
      }
    }
    return out;
  }

  /// X position of workout time [t] seconds.
  static double xAt(WorkoutPlan plan, Size size, double t) =>
      (t / math.max(1, plan.totalS)).clamp(0.0, 1.0) * size.width;
}

/// Planned blocks + actual power line + "now" cursor + FTP guide.
class WorkoutGraphPainter extends CustomPainter {
  WorkoutGraphPainter({
    required this.plan,
    required this.ftp,
    required this.elapsedS,
    required this.actual,
    this.actualVersion = 0,
  });

  final WorkoutPlan plan;
  final int ftp;
  final double elapsedS;

  /// Live view of the recorded power (may be the trace's own list).
  final List<({double t, double watts})> actual;

  /// [WorkoutTrace.version] of [actual]; the list itself is a live view, so
  /// identity / length alone can't tell whether it changed.
  final int actualVersion;

  @override
  void paint(Canvas canvas, Size size) {
    if (plan.steps.isEmpty || size.width <= 0 || size.height <= 0) return;
    // Scale from plan + FTP only: one sprint must not rescale every block
    // mid-ride (QA cycle 2). Spikes above the top are clipped.
    final ym = WorkoutGraphLayout.yMax(plan, ftp);
    final blocks = WorkoutGraphLayout.blocks(plan, size, ftp, yMaxW: ym);
    final nowX = WorkoutGraphLayout.xAt(plan, size, elapsedS);
    final current = plan.stepIndexAt(elapsedS);

    // Planned blocks: past dimmed, current strongest, future calm.
    for (final b in blocks) {
      final past = b.x1 <= nowX && b.index != current;
      final isCur = b.index == current;
      final alpha = isCur ? 0.55 : (past ? 0.22 : 0.38);
      final gap = b.width > 4 ? 0.75 : 0.0;
      final path = Path()
        ..moveTo(b.x0 + gap, size.height)
        ..lineTo(b.x0 + gap, b.yTop0)
        ..lineTo(b.x1 - gap, b.yTop1)
        ..lineTo(b.x1 - gap, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = b.color.withValues(alpha: alpha));
      canvas.drawLine(
        Offset(b.x0 + gap, b.yTop0),
        Offset(b.x1 - gap, b.yTop1),
        Paint()
          ..color = b.color.withValues(alpha: isCur ? 1 : 0.7)
          ..strokeWidth = isCur ? 2 : 1.25,
      );
    }

    // FTP guide.
    final ftpY = size.height * (1 - (ftp / ym).clamp(0.0, 1.0));
    final dash = Paint()
      ..color = RideColors.textMuted.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, ftpY),
        Offset(math.min(x + 4, size.width), ftpY),
        dash,
      );
    }
    final tp = TextPainter(
      text: TextSpan(
        text: 'FTP $ftp',
        style: const TextStyle(
          color: RideColors.textMuted,
          fontSize: RideType.footnote,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(4, math.max(0, ftpY - tp.height - 1)));

    // Actual power (min/max decimated to ~2 points per pixel column).
    final line = decimateMinMax(actual, math.max(4, size.width.ceil() * 2));
    if (line.length >= 2) {
      final p = Path();
      for (var i = 0; i < line.length; i++) {
        final x = WorkoutGraphLayout.xAt(plan, size, line[i].t);
        final y = size.height * (1 - (line[i].watts / ym).clamp(0.0, 1.0));
        i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      canvas.drawPath(
        p,
        Paint()
          ..color = RideColors.textPrimary.withValues(alpha: 0.92)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.75
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Now cursor.
    final cursor = Paint()
      ..color = RideColors.accent
      ..strokeWidth = 2;
    canvas.drawLine(Offset(nowX, 0), Offset(nowX, size.height), cursor);
    final tri = Path()
      ..moveTo(nowX - 5, 0)
      ..lineTo(nowX + 5, 0)
      ..lineTo(nowX, 6)
      ..close();
    canvas.drawPath(tri, Paint()..color = RideColors.accent);
  }

  @override
  bool shouldRepaint(WorkoutGraphPainter old) =>
      !identical(old.plan, plan) ||
      old.ftp != ftp ||
      old.elapsedS != elapsedS ||
      old.actualVersion != actualVersion ||
      old.actual.length != actual.length ||
      !identical(old.actual, actual);
}
