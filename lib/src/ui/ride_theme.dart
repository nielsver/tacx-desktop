import 'package:flutter/material.dart';

/// Shared dark-ride palette and control chrome for the ride dashboard.
abstract final class RideColors {
  static const bg = Color(0xFF0A0D11);
  static const surface = Color(0xFF12171F);
  static const surfaceHigh = Color(0xFF1A212C);
  static const border = Color(0xFF2A3340);
  static const textPrimary = Color(0xFFF2F5F8);
  static const textSecondary = Color(0xFF9AA7B5);

  /// Footnotes / hints. Was #6B7785 (≈3.6:1 on surfaceHigh); now ≥5:1 on
  /// every surface so captions stay readable (WCAG AA 4.5:1).
  static const textMuted = Color(0xFF8A96A4);

  /// Foreground for disabled buttons: still ≥4.5:1 on [surfaceHigh].
  static const textDisabled = Color(0xFF8592A0);
  static const accent = Color(0xFF4FC3F7);
  static const accentAlt = Color(0xFF26C6DA);
  static const power = Color(0xFFFF8A65);
  static const cadence = Color(0xFF81C784);
  static const speed = Color(0xFF64B5F6);
  static const control = Color(0xFFCE93D8);
  static const danger = Color(0xFFEF5350);
  static const warn = Color(0xFFFFB74D);
  static const ok = Color(0xFF66BB6A);
  static const demo = Color(0xFFE53935);
}

/// Ride type scale. Every font size in the dashboard comes from here so the
/// hierarchy (watts first, then targets, titles, body, captions) stays
/// consistent. See UX checklist P0-X1.
abstract final class RideType {
  /// Live power hero value.
  static const double hero = 48;

  /// ERG target watts / resistance percent.
  static const double target = 40;

  /// −/+ nudge glyphs.
  static const double glyph = 22;

  /// App title in the header.
  static const double header = 20;

  /// Secondary live metrics (cadence, speed).
  static const double metric = 18;

  /// Panel and empty-state titles.
  static const double title = 16;

  /// Body copy and buttons.
  static const double body = 14;

  /// Dense labels: status strips, chips, slider labels.
  static const double label = 13;

  /// Captions and units.
  static const double caption = 12;

  /// Footnotes and tiny hints.
  static const double footnote = 11;

  /// Every allowed size, largest first.
  static const List<double> all = [
    hero,
    target,
    glyph,
    header,
    metric,
    title,
    body,
    label,
    caption,
    footnote,
  ];
}

ThemeData buildRideTheme() {
  final scheme = ColorScheme.dark(
    surface: RideColors.surface,
    primary: RideColors.accent,
    secondary: RideColors.accentAlt,
    error: RideColors.danger,
    onPrimary: const Color(0xFF001018),
    onSurface: RideColors.textPrimary,
    outline: RideColors.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: RideColors.bg,
    fontFamily: 'Roboto',
  );

  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          bodyColor: RideColors.textPrimary,
          displayColor: RideColors.textPrimary,
        )
        .copyWith(
          headlineSmall: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: RideColors.textPrimary,
          ),
          titleMedium: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
            color: RideColors.textPrimary,
          ),
          bodyMedium: const TextStyle(
            fontSize: 14,
            height: 1.35,
            color: RideColors.textPrimary,
          ),
          bodySmall: const TextStyle(
            fontSize: 12,
            height: 1.35,
            color: RideColors.textSecondary,
          ),
          labelLarge: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: RideColors.textPrimary,
          ),
        ),
    cardTheme: CardThemeData(
      color: RideColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: RideColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: RideColors.surfaceHigh,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: RideColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: RideColors.accent, width: 1.5),
      ),
      labelStyle: const TextStyle(color: RideColors.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        disabledBackgroundColor: RideColors.surfaceHigh,
        disabledForegroundColor: RideColors.textDisabled,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: RideColors.border),
        disabledForegroundColor: RideColors.textDisabled,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 40),
        foregroundColor: RideColors.accent,
        disabledForegroundColor: RideColors.textDisabled,
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10),
      // 22px overlay radius = 44px hit area (touch-friendly sliders).
      overlayShape: RoundSliderOverlayShape(overlayRadius: 22),
      activeTrackColor: RideColors.accent,
      inactiveTrackColor: RideColors.border,
      thumbColor: RideColors.accent,
      overlayColor: Color(0x334FC3F7),
      valueIndicatorColor: RideColors.surfaceHigh,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return RideColors.accent;
        return RideColors.textSecondary;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return Colors.transparent;
        return RideColors.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected))
          return RideColors.accent.withValues(alpha: 0.45);
        return RideColors.border;
      }),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: RideColors.accent,
      linearTrackColor: RideColors.border,
    ),
  );
}

/// WCAG 2.x contrast ratio between two opaque colours (1.0 … 21.0).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
