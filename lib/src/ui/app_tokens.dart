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
    this.fast = const Duration(milliseconds: 150),
    this.medium = const Duration(milliseconds: 250),
  });

  /// xs, s, m, l, xl.
  final List<double> space;
  final double rSm, rMd, rLg;

  /// Z1..Z7.
  final List<Color> zones;

  /// Motion durations (subtle; zeroed when the OS asks for reduced motion).
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
  AppTokens get tk => Theme.of(this).extension<AppTokens>() ?? const AppTokens();
}
