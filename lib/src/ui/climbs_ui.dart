import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// "Climb", "Cat 4" … "HC" (Strava-style; score = length m × grade %).
String climbCatLabel(ClimbCat c) => switch (c) {
  ClimbCat.climb => 'Climb',
  ClimbCat.cat4 => 'Cat 4',
  ClimbCat.cat3 => 'Cat 3',
  ClimbCat.cat2 => 'Cat 2',
  ClimbCat.cat1 => 'Cat 1',
  ClimbCat.hc => 'HC',
};

/// Band colour: calm amber for small climbs, deeper red up to HC.
Color climbCatColor(ClimbCat c) => switch (c) {
  ClimbCat.climb => RideColors.warn,
  ClimbCat.cat4 || ClimbCat.cat3 => const Color(0xFFF08A3C),
  _ => RideColors.danger,
};

/// The climb containing [m] metres, if any.
Climb? climbAt(List<Climb> climbs, double? m) {
  if (m == null || !m.isFinite) return null;
  for (final c in climbs) {
    if (m >= c.startM && m <= c.endM) return c;
  }
  return null;
}

/// "Cat 4 · 2.0 km · +100 m · 5.0 %".
String climbSummary(Climb c) =>
    '${climbCatLabel(c.category)} · '
    '${((c.endM - c.startM) / 1000).toStringAsFixed(1)} km · '
    '+${c.gainM.round()} m · ${c.avgGrade.toStringAsFixed(1)} %';

/// Live chip text while on a climb: "Cat 4 · 1.2 km to top · 5.1 %".
String? climbLiveText(List<Climb> climbs, double? riderM) {
  final c = climbAt(climbs, riderM);
  if (c == null) return null;
  final left = ((c.endM - riderM!) / 1000).clamp(0.0, 999.0);
  return '${climbCatLabel(c.category)} · ${left.toStringAsFixed(1)} km to top'
      ' · ${c.avgGrade.toStringAsFixed(1)} %';
}

/// Shaded, labelled climb bands under the elevation line (static layer).
class ClimbBandsPainter extends CustomPainter {
  ClimbBandsPainter(this.climbs, this.distanceM);

  final List<Climb> climbs;
  final double distanceM;

  @override
  void paint(Canvas canvas, Size size) {
    if (climbs.isEmpty || distanceM <= 0) return;
    for (final c in climbs) {
      final x0 = c.startM / distanceM * size.width;
      final x1 = c.endM / distanceM * size.width;
      final color = climbCatColor(c.category);
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, x1, size.height),
        Paint()..color = color.withValues(alpha: 0.12),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: climbCatLabel(c.category),
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (tp.width + 4 <= x1 - x0) {
        tp.paint(canvas, Offset(x0 + 2, size.height - tp.height - 2));
      }
    }
  }

  @override
  bool shouldRepaint(ClimbBandsPainter old) =>
      !identical(old.climbs, climbs) || old.distanceM != distanceM;
}
