import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

void main() {
  const surfaces = {
    'bg': RideColors.bg,
    'surface': RideColors.surface,
    'surfaceHigh': RideColors.surfaceHigh,
  };

  // Text and actionable colours must reach WCAG AA (4.5:1) on every surface.
  const aa = {
    'textPrimary': RideColors.textPrimary,
    'textSecondary': RideColors.textSecondary,
    'textMuted': RideColors.textMuted,
    'textDisabled': RideColors.textDisabled,
    'accent': RideColors.accent,
    'danger': RideColors.danger,
    'warn': RideColors.warn,
    'control': RideColors.control,
  };

  for (final fg in aa.entries) {
    for (final bg in surfaces.entries) {
      test('${fg.key} on ${bg.key} >= 4.5:1', () {
        final r = contrastRatio(fg.value, bg.value);
        expect(
          r,
          greaterThanOrEqualTo(4.5),
          reason: '${fg.key} on ${bg.key} is ${r.toStringAsFixed(2)}:1',
        );
      });
    }
  }

  test('disabled FilledButton uses readable theme colours', () {
    final theme = buildRideTheme();
    final style = theme.filledButtonTheme.style!;
    final fg = style.foregroundColor!.resolve({WidgetState.disabled})!;
    final bg = style.backgroundColor!.resolve({WidgetState.disabled})!;
    expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5));
  });

  test('slider hit area is at least 44px', () {
    final theme = buildRideTheme();
    final overlay = theme.sliderTheme.overlayShape!;
    final size = overlay.getPreferredSize(true, false);
    expect(size.height, greaterThanOrEqualTo(44));
  });
}
