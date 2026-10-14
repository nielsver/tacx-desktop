import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/util/reveal_in_folder.dart';
import 'package:tacx_desktop/src/progress/progress_ui.dart';
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
    this.earned,
    this.onProgressSettings,
    this.note,
  });

  final String title;
  final RideSummary summary;
  final RideStats stats;
  final bool isDemo;
  final RouteResult? route;

  /// "What you earned" (null: Demo, or progress turned off).
  final EarnedPayload? earned;
  final VoidCallback? onProgressSettings;

  /// One muted line under the title (e.g. why records weren't updated).
  final String? note;
}

/// Post-ride summary (step 3, PS2): totals, NP / IF / TSS, best efforts,
/// time in zone, power trace, and for GPX rides the map and ghost result.
/// Demo rides carry a DEMO tag and never touch the ghost store.
class RideSummaryView extends StatelessWidget {
  const RideSummaryView({
    super.key,
    required this.data,
    required this.saveTcx,
    required this.onDone,
    this.reveal,
  });

  final RideSummaryData data;

  /// Writes the ride's TCX and returns its path (throws on failure).
  final Future<String> Function()? saveTcx;
  final VoidCallback onDone;

  /// File-manager / browser seam (tests inject a fake).
  final Reveal? reveal;

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
            if (data.note != null)
              Padding(
                padding: EdgeInsets.only(top: tk.xs),
                child: Text(
                  data.note!,
                  key: const ValueKey('summary-note'),
                  style: const TextStyle(
                    color: RideColors.textMuted,
                    fontSize: RideType.caption,
                  ),
                ),
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
            if (data.earned != null) ...[
              EarnedRow(
                earned: data.earned!,
                onSettings: data.onProgressSettings,
              ),
              SizedBox(height: tk.s),
            ],
            SummaryActions(
              isDemo: data.isDemo,
              saveTcx: saveTcx,
              reveal: reveal ?? Reveal(),
              onDone: onDone,
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
  required Future<String> Function() saveTcx,
  Reveal? reveal,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: RideSummaryView(
        data: data,
        saveTcx: saveTcx,
        reveal: reveal,
        onDone: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

/// Save TCX · Show in folder · Garmin Connect import · Done (step 4, R2).
/// Results show inside the dialog (a snackbar would sit behind the modal).
class SummaryActions extends StatefulWidget {
  const SummaryActions({
    super.key,
    required this.isDemo,
    required this.saveTcx,
    required this.reveal,
    required this.onDone,
  });

  final bool isDemo;
  final Future<String> Function()? saveTcx;
  final Reveal reveal;
  final VoidCallback onDone;

  static const demoRefusal =
      'Demo rides are synthetic — they are never sent to Garmin Connect.';

  @override
  State<SummaryActions> createState() => _SummaryActionsState();
}

class _SummaryActionsState extends State<SummaryActions> {
  String? _path;
  String? _status;
  bool _error = false;
  bool _busy = false;

  Future<String?> _save() async {
    final p = _path;
    if (p != null) return p; // never a second file
    final save = widget.saveTcx;
    if (save == null) return null;
    try {
      final path = await save();
      _path = path;
      _set('Saved $path');
      return path;
    } catch (e) {
      _set('$e', error: true);
      return null;
    }
  }

  void _set(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _error = error;
    });
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _show() async {
    final p = await _save();
    if (p == null) return;
    final ok = await widget.reveal.showInFolder(p);
    if (!ok) _set('Could not open the folder. File: $p', error: true);
  }

  Future<void> _garmin() async {
    if (widget.isDemo) {
      _set(SummaryActions.demoRefusal, error: true);
      return;
    }
    final p = await _save();
    if (p == null) return;
    await widget.reveal.showInFolder(p);
    final ok = await widget.reveal.openUrl(kGarminImportUrl);
    _set(
      ok
          ? 'Drag ${p.split(RegExp(r'[/\\]')).last} onto Garmin Connect → Import Data.'
          : 'Open $kGarminImportUrl and import $p',
      error: !ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final canSave = widget.saveTcx != null && !_busy;
    final status = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status != null)
          Padding(
            padding: EdgeInsets.only(bottom: tk.s),
            child: Text(
              status,
              key: const ValueKey('summary-status'),
              textAlign: TextAlign.end,
              style: TextStyle(
                color: _error ? RideColors.danger : RideColors.textSecondary,
                fontSize: RideType.caption,
              ),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: tk.s,
          runSpacing: tk.s,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('summary-save-tcx'),
              onPressed: canSave && _path == null ? () => _guard(_save) : null,
              icon: Icon(_path == null ? Icons.save_alt : Icons.check, size: 18),
              label: Text(_path == null ? 'Save TCX' : 'Saved'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('summary-show-folder'),
              onPressed: canSave ? () => _guard(_show) : null,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Show in folder'),
            ),
            Tooltip(
              message: widget.isDemo
                  ? SummaryActions.demoRefusal
                  : 'Save the TCX, show it, and open Garmin Connect import',
              child: OutlinedButton.icon(
                key: const ValueKey('summary-garmin'),
                onPressed: canSave && !widget.isDemo
                    ? () => _guard(_garmin)
                    : null,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Garmin Connect'),
              ),
            ),
            FilledButton(
              key: const ValueKey('summary-done'),
              onPressed: widget.onDone,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }
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
