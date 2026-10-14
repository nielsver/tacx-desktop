import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart'
    show kZoneColors, powerZone;

/// Tabular (fixed-width) digits: live numbers must not jitter as they
/// change (1 → 111 W keeps every digit the same width).
const List<FontFeature> kTabularFeatures = [FontFeature.tabularFigures()];

/// Merge into any style that shows a live number.
const TextStyle kTabular = TextStyle(fontFeatures: kTabularFeatures);

/// Design tokens (step 3, DT1): spacing scale, radii and the Coggan zone
/// palette as one ThemeExtension. Zones reuse [kZoneColors] / [powerZone]
/// as the single source of truth.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    this.space = const [4, 8, 12, 16, 24],
    this.rSm = 8,
    this.rMd = 12,
    this.rLg = 16,
    this.zones = kZoneColors,
    this.fast = const Duration(milliseconds: 150), // = AppMotion.normal.fast
    this.medium = const Duration(
      milliseconds: 250,
    ), // = AppMotion.normal.medium
  });

  /// xs, s, m, l, xl.
  final List<double> space;
  final double rSm, rMd, rLg;

  /// Z1..Z7.
  final List<Color> zones;

  /// Motion durations; prefer [AppMotion.of], which zeroes them when the OS
  /// asks for reduced motion.
  final Duration fast, medium;

  double get xs => space[0];
  double get s => space[1];
  double get m => space[2];
  double get l => space[3];
  double get xl => space[4];

  BorderRadius get radiusSm => BorderRadius.circular(rSm);
  BorderRadius get radiusMd => BorderRadius.circular(rMd);
  BorderRadius get radiusLg => BorderRadius.circular(rLg);

  /// Zone colour for [watts] at [ftp] (Coggan bands).
  Color zoneFor(double watts, int ftp) => zones[powerZone(watts, ftp) - 1];

  @override
  AppTokens copyWith({
    List<double>? space,
    double? rSm,
    double? rMd,
    double? rLg,
    List<Color>? zones,
    Duration? fast,
    Duration? medium,
  }) => AppTokens(
    space: space ?? this.space,
    rSm: rSm ?? this.rSm,
    rMd: rMd ?? this.rMd,
    rLg: rLg ?? this.rLg,
    zones: zones ?? this.zones,
    fast: fast ?? this.fast,
    medium: medium ?? this.medium,
  );

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      space: [
        for (var i = 0; i < space.length; i++)
          lerpDouble(space[i], other.space[i], t)!,
      ],
      rSm: lerpDouble(rSm, other.rSm, t)!,
      rMd: lerpDouble(rMd, other.rMd, t)!,
      rLg: lerpDouble(rLg, other.rLg, t)!,
      zones: [
        for (var i = 0; i < zones.length; i++)
          Color.lerp(zones[i], other.zones[i], t)!,
      ],
      fast: t < 0.5 ? fast : other.fast,
      medium: t < 0.5 ? medium : other.medium,
    );
  }
}

extension AppTokensX on BuildContext {
  /// Design tokens of the current theme (defaults if none registered).
  AppTokens get tk =>
      Theme.of(this).extension<AppTokens>() ?? const AppTokens();
}

/// Motion tokens (step 3, subtle motion): one set of durations + curves.
///
/// [AppMotion.of] returns [AppMotion.reduced] (all zero, linear) when the
/// OS / Flutter asks to reduce motion (`MediaQuery.disableAnimations`), so
/// every animation that uses these tokens snaps instead of moving.
@immutable
class AppMotion {
  const AppMotion({
    required this.fast,
    required this.medium,
    required this.pulse,
    required this.standard,
    required this.emphasized,
  });

  /// Small state changes (hover, chips).
  final Duration fast;

  /// Value transitions (target watts).
  final Duration medium;

  /// One-shot attention cue (interval change).
  final Duration pulse;

  /// Ease-out for values settling.
  final Curve standard;

  /// Fade of the interval pulse.
  final Curve emphasized;

  static const AppMotion normal = AppMotion(
    fast: Duration(milliseconds: 150),
    medium: Duration(milliseconds: 250),
    pulse: Duration(milliseconds: 700),
    standard: Curves.easeOutCubic,
    emphasized: Curves.easeOutQuart,
  );

  static const AppMotion reduced = AppMotion(
    fast: Duration.zero,
    medium: Duration.zero,
    pulse: Duration.zero,
    standard: Curves.linear,
    emphasized: Curves.linear,
  );

  bool get enabled => pulse > Duration.zero;

  static AppMotion of(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? reduced
      : normal;
}

extension AppMotionX on BuildContext {
  AppMotion get motion => AppMotion.of(this);
}

/// Plays a brief accent wash behind [child] whenever [trigger] changes
/// (e.g. the workout step index). Static under reduced motion.
class IntervalPulse extends StatefulWidget {
  const IntervalPulse({
    super.key,
    required this.trigger,
    required this.color,
    required this.child,
  });

  final Object trigger;
  final Color color;
  final Widget child;

  @override
  State<IntervalPulse> createState() => _IntervalPulseState();
}

class _IntervalPulseState extends State<IntervalPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: 0,
  );

  @override
  void didUpdateWidget(IntervalPulse old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) {
      final m = AppMotion.of(context);
      if (!m.enabled) return; // reduced motion: no pulse at all
      _c.duration = m.pulse;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Current wash opacity (for tests).
  @visibleForTesting
  double get debugValue => _c.isAnimating ? 1 - _c.value : 0;

  @override
  Widget build(BuildContext context) {
    final m = AppMotion.of(context);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.isAnimating ? 1 - m.emphasized.transform(_c.value) : 0.0;
        return DecoratedBox(
          key: const ValueKey('interval-pulse'),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.18 * t),
            borderRadius: context.tk.radiusSm,
          ),
          child: child,
        );
      },
    );
  }
}

/// Number that eases to its new value (target watts). Snaps when motion is
/// reduced or on the first build.
class AnimatedNumber extends StatelessWidget {
  const AnimatedNumber({super.key, required this.value, required this.builder});

  final double value;
  final Widget Function(BuildContext context, double value) builder;

  @override
  Widget build(BuildContext context) {
    final m = AppMotion.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: m.medium,
      curve: m.standard,
      builder: (context, v, _) => builder(context, v),
    );
  }
}
