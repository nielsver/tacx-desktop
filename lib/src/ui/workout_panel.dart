import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart' show fmtClock;

/// Workouts + GPX setup (edit only outside Focus).
class WorkoutPanel extends StatelessWidget {
  const WorkoutPanel({
    super.key,
    required this.workouts,
    required this.workoutStatus,
    required this.routeStatus,
    required this.gpxProfile,
    required this.ergFromGrade,
    required this.enabled,
    required this.supportsSimulation,
    required this.onRefreshList,
    required this.onStartWorkout,
    required this.onStopWorkout,
    required this.onImportGpxXml,
    required this.onStartRoute,
    required this.onStopRoute,
    required this.onErgFromGrade,
    required this.onSaveAsCopy,
    this.ghostM,
    this.ghostDeltaS,
    this.bestS,
  });

  final List<WorkoutInfo> workouts;
  final WorkoutStatus workoutStatus;
  final RouteStatus routeStatus;
  final GpxProfileInfo? gpxProfile;
  final bool ergFromGrade;
  final bool enabled;
  final bool supportsSimulation;
  final VoidCallback onRefreshList;
  final ValueChanged<String> onStartWorkout;
  final VoidCallback onStopWorkout;
  final ValueChanged<String> onImportGpxXml;
  final VoidCallback onStartRoute;
  final VoidCallback onStopRoute;
  final ValueChanged<bool> onErgFromGrade;
  final ValueChanged<WorkoutInfo> onSaveAsCopy;

  /// Ghost (best attempt) position on the loaded route, metres.
  final double? ghostM;

  /// Seconds behind (+) / ahead (−) of the best attempt while riding.
  final double? ghostDeltaS;

  /// Best time on the loaded route, seconds (null = no attempt yet).
  final double? bestS;

  @override
  Widget build(BuildContext context) {
    final active = workoutStatus.running || routeStatus.running;
    return Card(
      key: const ValueKey('workout-panel'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Workouts',
              style: TextStyle(
                fontSize: RideType.title,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              active
                  ? (workoutStatus.running
                      ? workoutStatus.statusText
                      : routeStatus.statusText)
                  : 'Built-ins + saved JSON · edit outside Focus',
              style: const TextStyle(
                fontSize: RideType.label,
                fontWeight: FontWeight.w600,
                color: RideColors.textPrimary,
              ),
            ),
            if (ghostDeltaS != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GhostDeltaChip(deltaS: ghostDeltaS!),
                ),
              ),
            if (routeStatus.complete)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Route complete — grade set to 0%',
                  key: ValueKey('route-complete-banner'),
                  style: TextStyle(
                    color: RideColors.ok,
                    fontWeight: FontWeight.w700,
                    fontSize: RideType.caption,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final w in workouts) ...[
                    SizedBox(
                      height: 44,
                      child: FilledButton.tonal(
                        onPressed: enabled && !active
                            ? () => onStartWorkout(w.id)
                            : null,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            w.builtin ? w.name : '${w.name} (saved)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8, top: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${w.stepCount} steps · ${_fmtDur(w.totalDurationS)}'
                              '${w.description.isEmpty ? '' : ' — ${w.description}'}',
                              style: const TextStyle(
                                color: RideColors.textSecondary,
                                fontSize: RideType.caption,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (w.builtin)
                            TextButton(
                              onPressed: enabled
                                  ? () => onSaveAsCopy(w)
                                  : null,
                              child: const Text('Save copy'),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const Divider(height: 16),
                  const Text(
                    'GPX → Simulation grade',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        key: const ValueKey('gpx-paste'),
                        onPressed: enabled
                            ? () => _pasteGpx(context)
                            : null,
                        child: const Text('Paste GPX'),
                      ),
                      FilledButton(
                        key: const ValueKey('gpx-start'),
                        onPressed: enabled &&
                                gpxProfile != null &&
                                (supportsSimulation) &&
                                !active
                            ? onStartRoute
                            : null,
                        child: const Text('Start route'),
                      ),
                      OutlinedButton(
                        onPressed: routeStatus.running ? onStopRoute : null,
                        child: const Text('Stop route'),
                      ),
                    ],
                  ),
                  if (!supportsSimulation)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Trainer has no simulation — use an ERG workout instead.',
                        style: TextStyle(
                          color: RideColors.warn,
                          fontSize: RideType.caption,
                        ),
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text(
                      'ERG from grade (optional)',
                      style: TextStyle(fontSize: RideType.label),
                    ),
                    subtitle: const Text(
                      'Default off. Kickr may lag 3–5 s.',
                      style: TextStyle(fontSize: RideType.caption),
                    ),
                    value: ergFromGrade,
                    onChanged: enabled ? onErgFromGrade : null,
                  ),
                  if (gpxProfile != null) ...[
                    const SizedBox(height: 6),
                    ElevProfileChart(
                      profile: gpxProfile!,
                      progressM: routeStatus.running || routeStatus.complete
                          ? routeStatus.progressM
                          : null,
                      ghostM: routeStatus.running ? ghostM : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        bestS == null
                            ? 'No best yet — finish the route to set a ghost'
                            : 'Best ${fmtClock(bestS!)} · ghost ◦ on the profile',
                        key: const ValueKey('route-best'),
                        style: const TextStyle(
                          color: RideColors.textMuted,
                          fontSize: RideType.caption,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                key: const ValueKey('workout-stop'),
                onPressed: (workoutStatus.running || enabled)
                    ? onStopWorkout
                    : null,
                child: const Text('Stop workout'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pasteGpx(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !text.contains('<trkpt')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Clipboard has no GPX track — copy a .gpx file first'),
          ),
        );
      }
      return;
    }
    onImportGpxXml(text);
  }

  static String _fmtDur(int s) {
    final m = s ~/ 60;
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

/// Light create dialog: name + list of ERG steps → save JSON.
Future<void> showCreateWorkoutDialog(BuildContext context) async {
  final nameCtrl = TextEditingController(text: 'Custom ERG');
  final steps = <({int dur, int watts})>[(dur: 300, watts: 150)];
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            backgroundColor: RideColors.surface,
            title: const Text('New ERG workout'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < steps.length; i++)
                    Row(
                      children: [
                        Expanded(
                          child: Text('Step ${i + 1}: ${steps[i].watts} W × ${steps[i].dur}s'),
                        ),
                        IconButton(
                          onPressed: () => setLocal(() => steps.removeAt(i)),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      final dur = TextEditingController(text: '300');
                      final watts = TextEditingController(text: '200');
                      final add = await showDialog<bool>(
                        context: ctx,
                        builder: (c2) => AlertDialog(
                          title: const Text('Add ERG step'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                controller: watts,
                                decoration:
                                    const InputDecoration(labelText: 'Watts'),
                                keyboardType: TextInputType.number,
                              ),
                              TextField(
                                controller: dur,
                                decoration: const InputDecoration(
                                  labelText: 'Duration (s)',
                                ),
                                keyboardType: TextInputType.number,
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c2, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c2, true),
                              child: const Text('Add'),
                            ),
                          ],
                        ),
                      );
                      if (add == true) {
                        setLocal(() {
                          steps.add((
                            dur: int.tryParse(dur.text) ?? 300,
                            watts: int.tryParse(watts.text) ?? 150,
                          ));
                        });
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add step'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: steps.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
  if (ok != true || steps.isEmpty) return;
  final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
  final stepJson = steps
      .map((s) =>
          '{"kind":"erg","durationS":${s.dur},"watts":${s.watts}}')
      .join(',');
  final json =
      '{"version":1,"id":"$id","name":"${nameCtrl.text.replaceAll('"', '')}",'
      '"description":"","builtin":false,"steps":[$stepJson]}';
  api.saveWorkoutJson(json: json);
}
