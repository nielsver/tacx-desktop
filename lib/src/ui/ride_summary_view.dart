import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart' show fmtDelta;
import 'package:tacx_desktop/src/workout/workout_plan.dart'
    show fmtClock, kZoneColors;

/// Route part of a post-ride summary (GPX rides only).
@immutable
class RouteResult {
  const RouteResult({
    required this.name,
    required this.geo,
    required this.progressM,
    required this.complete,
    required this.elevGainM,
    this.finishS,
    this.bestS,
    this.newBest = false,
  });

  final String name;
  final RouteGeo geo;
  final double progressM;
  final bool complete;

  /// Climbed over [0, progressM] (2 m hysteresis, like the GPX header).
  final double elevGainM;

  /// Finish time when [complete].
  final double? finishS;

  /// Best before this ride (null = none yet).
  final double? bestS;
  final bool newBest;
}

/// Everything the summary screen shows; built once when the ride ends.
@immutable
class RideSummaryData {
  const RideSummaryData({
    required this.title,
    required this.summary,
    required this.stats,
    required this.isDemo,
    this.route,
  });

  final String title;
  final RideSummary summary;
  final RideStats stats;
  final bool isDemo;
  final RouteResult? route;
}

/// Post-ride summary (step 3, PS2): totals, NP / IF / TSS, best efforts,
/// time in zone, power trace, and for GPX rides the map and ghost result.
/// Demo rides carry a DEMO tag and never touch the ghost store.
class RideSummaryView extends StatelessWidget {
  const RideSummaryView({
    super.key,
    required this.data,
    required this.onSaveTcx,
    required this.onDone,
  });

  final RideSummaryData data;
  final VoidCallback? onSaveTcx;
  final VoidCallback onDone;

  static String watts(double? w) => w == null ? '—' : '${w.round()} W';
  static String dec(double? v, int places) =>
      v == null ? '—' : v.toStringAsFixed(places);

  static String bestLabel(int s) => switch (s) {
    < 60 => '$s s',
    _ => '${s ~/ 60} min',
  };

  /// "−0:12 vs best · new best", "+0:30 vs best", "First finish", "Stopped at 4.2 / 10.0 km".
  static String ghostLine(RouteResult r) {
    if (!r.complete) {
      return 'Stopped at ${(r.progressM / 1000).toStringAsFixed(1)} / '
          '${(r.geo.distanceM / 1000).toStringAsFixed(1)} km';
    }
    final f = r.finishS;
    final b = r.bestS;
    if (f == null) return 'Finished';
    if (b == null) return 'Finished in ${fmtClock(f)} · first finish';
    final delta = fmtDelta(f - b);
    return 'Finished in ${fmtClock(f)} · $delta vs best'
        '${r.newBest ? ' · new best' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final s = data.summary;
    final st = data.stats;
    final route = data.route;
    return Container(
      key: const ValueKey('ride-summary'),
      constraints: const BoxConstraints(maxWidth: 760),
      padding: EdgeInsets.all(tk.l),
      decoration: BoxDecoration(
        color: RideColors.surface,
        borderRadius: tk.radiusLg,
        border: Border.all(color: RideColors.border),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: RideColors.textPrimary,
                      fontSize: RideType.header,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (data.isDemo)
                  Container(
                    key: const ValueKey('summary-demo'),
                    padding: EdgeInsets.symmetric(
                      horizontal: tk.s,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: RideColors.demo,
                      borderRadius: tk.radiusSm,
                    ),
                    child: const Text(
                      'DEMO',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        fontSize: RideType.caption,
                      ),
                    ),
                  ),
              ],
            ),
            if (data.isDemo)
              Padding(
                padding: EdgeInsets.only(top: tk.xs),
                child: const Text(
                  'Demo data: not a real effort, never saved as a ghost.',
                  style: TextStyle(
                    color: RideColors.textMuted,
                    fontSize: RideType.caption,
                  ),
                ),
              ),
            SizedBox(height: tk.m),
            Wrap(
              spacing: tk.s,
              runSpacing: tk.s,
              children: [
                _Stat(
                  'Time',
                  _clock(st.elapsedS),
                  key: const ValueKey('sum-time'),
                ),
                _Stat('Distance', '${st.distanceKm.toStringAsFixed(2)} km'),
                _Stat('Avg power', watts(s.recordedS > 0 ? s.avgPowerW : null)),
                _Stat('NP', watts(s.npW), key: const ValueKey('sum-np')),
                _Stat(
                  'IF',
                  dec(s.intensityFactor, 2),
                  key: const ValueKey('sum-if'),
                ),
                _Stat('TSS', dec(s.tss, 0), key: const ValueKey('sum-tss')),
                _Stat('Energy', '${st.energyKj.round()} kJ'),
                _Stat(
                  'Cadence',
                  s.avgCadenceRpm > 0
                      ? '${s.avgCadenceRpm.round()} / ${s.maxCadenceRpm.round()} rpm'
                      : '—',
                ),
                _Stat(
                  'Heart rate',
                  s.maxHeartRateBpm > 0
                      ? '${s.avgHeartRateBpm.round()} / ${s.maxHeartRateBpm} bpm'
                      : '—',
                ),
                if (route != null)
                  _Stat(
                    'Climbed',
                    '${route.elevGainM.round()} m',
                    key: const ValueKey('sum-climb'),
                  ),
              ],
            ),
            if (s.ftpW == 0)
              Padding(
                padding: EdgeInsets.only(top: tk.xs),
                child: const Text(
                  'Set your FTP for IF, TSS and zones.',
                  style: TextStyle(
                    color: RideColors.textMuted,
                    fontSize: RideType.caption,
                  ),
                ),
              ),
            SizedBox(height: tk.l),
            const _Heading('Best efforts'),
            SizedBox(height: tk.xs),
            Row(
              children: [
                for (final b in s.bestPower)
                  Expanded(
                    child: _Stat(
                      bestLabel(b.durationS),
                      watts(b.watts),
                      key: ValueKey('sum-best-${b.durationS}'),
                      expand: true,
                    ),
                  ),
              ],
            ),
            if (s.timeInZoneS.length == 7 && s.recordedS > 0) ...[
              SizedBox(height: tk.l),
              _Heading('Time in zone · FTP ${s.ftpW} W'),
              SizedBox(height: tk.xs),
              ZoneBars(seconds: s.timeInZoneS),
            ],
            if (s.powerSeries.length >= 2) ...[
              SizedBox(height: tk.l),
              const _Heading('Power'),
              SizedBox(height: tk.xs),
              SizedBox(
                height: 72,
                child: CustomPaint(
                  key: const ValueKey('sum-power-chart'),
                  painter: SummaryPowerPainter(s.powerSeries, ftp: s.ftpW),
                  size: Size.infinite,
                ),
              ),
            ],
            if (route != null) ...[
              SizedBox(height: tk.l),
              _Heading(route.name),
              SizedBox(height: tk.xs),
              Text(
                ghostLine(route),
                key: const ValueKey('sum-ghost'),
                style: TextStyle(
                  color: route.newBest
                      ? RideColors.ok
                      : RideColors.textSecondary,
                  fontSize: RideType.body,
                  fontWeight: FontWeight.w600,
                  fontFeatures: kTabularFeatures,
                ),
              ),
              if (route.geo.isDrawable) ...[
                SizedBox(height: tk.s),
                Container(
                  height: 140,
                  decoration: BoxDecoration(
                    color: RideColors.bg,
                    borderRadius: tk.radiusSm,
                    border: Border.all(color: RideColors.border),
                  ),
                  child: RouteMap(
                    geo: route.geo,
                    progressM: _Fixed(route.progressM),
                    ghostM: const _Fixed(null),
                  ),
                ),
              ],
            ],
            SizedBox(height: tk.l),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('summary-save-tcx'),
                  onPressed: onSaveTcx,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Save TCX'),
                ),
                SizedBox(width: tk.s),
                FilledButton(
                  key: const ValueKey('summary-done'),
                  onPressed: onDone,
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _clock(int seconds) {
    final h = seconds ~/ 3600;
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// Shows the summary as a modal dialog. Resolves when the rider closes it.
Future<void> showRideSummary(
  BuildContext context, {
  required RideSummaryData data,
  required Future<void> Function() onSaveTcx,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: RideSummaryView(
        data: data,
        onSaveTcx: () => onSaveTcx(),
        onDone: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

class _Fixed<T> implements ValueListenable<T> {
  const _Fixed(this.value);
  @override
  final T value;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      color: RideColors.textSecondary,
      fontSize: RideType.caption,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {super.key, this.expand = false});
  final String label;
  final String value;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      width: expand ? null : 132,
      margin: expand ? EdgeInsets.only(right: tk.s) : null,
      padding: EdgeInsets.symmetric(horizontal: tk.m, vertical: tk.s),
      decoration: BoxDecoration(
        color: RideColors.surfaceHigh,
        borderRadius: tk.radiusSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: RideColors.textMuted,
              fontSize: RideType.caption,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: RideColors.textPrimary,
              fontSize: RideType.title,
              fontWeight: FontWeight.w700,
              fontFeatures: kTabularFeatures,
            ),
          ),
        ],
      ),
    );
  }
}

/// Z1–Z7 horizontal bars with share of ride time.
class ZoneBars extends StatelessWidget {
  const ZoneBars({super.key, required this.seconds});
  final List<int> seconds;

  @override
  Widget build(BuildContext context) {
    final total = seconds.fold<int>(0, (a, b) => a + b);
    final tk = context.tk;
    return Column(
      children: [
        for (var z = 0; z < 7; z++)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    'Z${z + 1}',
                    style: const TextStyle(
                      color: RideColors.textMuted,
                      fontSize: RideType.caption,
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: tk.radiusSm,
                    child: LinearProgressIndicator(
                      key: ValueKey('zone-bar-${z + 1}'),
                      value: total == 0 ? 0 : seconds[z] / total,
                      minHeight: 8,
                      backgroundColor: RideColors.surfaceHigh,
                      color: kZoneColors[z],
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    RideSummaryView._clock(seconds[z]),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: RideColors.textSecondary,
                      fontSize: RideType.caption,
                      fontFeatures: kTabularFeatures,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Whole-ride power line (≤ 600 bucket means) with a dashed FTP line.
class SummaryPowerPainter extends CustomPainter {
  SummaryPowerPainter(this.series, {required this.ftp});
  final List<double> series;
  final int ftp;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2 || size.width <= 0 || size.height <= 0) return;
    final top = math.max(series.reduce(math.max), ftp * 1.2).clamp(1.0, 3000.0);
    double y(double w) => size.height * (1 - (w / top).clamp(0.0, 1.0));
    final dx = size.width / (series.length - 1);
    final path = Path()..moveTo(0, y(series.first));
    for (var i = 1; i < series.length; i++) {
      path.lineTo(i * dx, y(series[i]));
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = RideColors.power.withValues(alpha: 0.15),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = RideColors.power,
    );
    if (ftp > 0) {
      final fy = y(ftp.toDouble());
      final p = Paint()
        ..color = RideColors.textMuted
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(
          Offset(x, fy),
          Offset(math.min(x + 4, size.width), fy),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SummaryPowerPainter old) =>
      !identical(old.series, series) || old.ftp != ftp;
}
