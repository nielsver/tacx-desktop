import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Rider-facing badge names.
String badgeLabel(String id) => switch (id) {
  'first_ride' => 'First ride',
  'first_route' => 'First route',
  'first_workout' => 'First workout',
  'first_ftp_test' => 'First FTP test',
  'ftp_up' => 'FTP up',
  'hour_ride' => 'Hour ride',
  'km_100' => '100 km',
  'km_500' => '500 km',
  'km_1000' => '1000 km',
  'ghost_beat' => 'Ghost beaten',
  'streak_4w' => '4-week streak',
  'climb_pr' => 'Climb PR',
  _ => id,
};

/// ●●○ for this week's ride days vs the weekly target.
String weekDots(int days, int target) {
  final t = target.clamp(1, 7);
  return List.generate(t, (i) => i < days ? '●' : '○').join();
}

/// "Form +4 (fit 52 · fatigue 48)".
String formText(EarnedPayload e) {
  final f = e.form.round();
  return 'Form ${f > 0 ? '+' : ''}$f '
      '(fitness ${e.ctl.round()} · fatigue ${e.atl.round()})';
}

/// One "what you earned" row on the post-ride summary: XP, streak dots,
/// new badges, PR deltas and form today. Muted, single block.
class EarnedRow extends StatelessWidget {
  const EarnedRow({super.key, required this.earned, this.onSettings});

  final EarnedPayload earned;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final e = earned;
    final parts = <String>[
      '+${e.xpGained} XP · level ${e.level}',
      '${e.streakWeeks}-week streak ${weekDots(e.weekDays, e.weeklyTarget)}',
      formText(e),
    ];
    const muted = TextStyle(
      color: RideColors.textSecondary,
      fontSize: RideType.caption,
      fontFeatures: kTabularFeatures,
    );
    return Container(
      key: const ValueKey('summary-earned'),
      padding: EdgeInsets.all(tk.s),
      decoration: BoxDecoration(
        color: RideColors.bg,
        borderRadius: tk.radiusSm,
        border: Border.all(color: RideColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(parts.join('   ·   '), style: muted),
                if (e.newBadges.isNotEmpty || e.prLines.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: tk.xs),
                    child: Wrap(
                      spacing: tk.s,
                      runSpacing: tk.xs,
                      children: [
                        for (final b in e.newBadges)
                          Chip(
                            key: ValueKey('earned-badge-$b'),
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.military_tech, size: 16),
                            label: Text(badgeLabel(b)),
                          ),
                        for (final p in e.prLines)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(
                              Icons.landscape_outlined,
                              size: 16,
                            ),
                            label: Text(p),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (onSettings != null)
            IconButton(
              key: const ValueKey('earned-settings'),
              tooltip: 'Progress & badges',
              visualDensity: VisualDensity.compact,
              onPressed: onSettings,
              icon: const Icon(Icons.tune, size: 18),
            ),
        ],
      ),
    );
  }
}

/// Progress & badges settings: on/off, weekly target, earned badges and a
/// rebuild from saved TCX files.
Future<void> showProgressSettings(
  BuildContext context, {
  required bool enabled,
  required int weeklyTarget,
  required List<String> badges,
  required ValueChanged<bool> onEnabled,
  required ValueChanged<int> onTarget,
  required Future<String> Function() onRebuild,
}) {
  var on = enabled, target = weeklyTarget;
  String? note;
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        key: const ValueKey('progress-settings'),
        title: const Text('Progress & badges'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('progress-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show XP, streaks and badges'),
                subtitle: const Text('Local only. Demo rides never count.'),
                value: on,
                onChanged: (v) {
                  set(() => on = v);
                  onEnabled(v);
                },
              ),
              Row(
                children: [
                  const Expanded(child: Text('Ride days per week')),
                  IconButton(
                    onPressed: target > 1
                        ? () {
                            set(() => target--);
                            onTarget(target);
                          }
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text('$target', key: const ValueKey('progress-target')),
                  IconButton(
                    onPressed: target < 7
                        ? () {
                            set(() => target++);
                            onTarget(target);
                          }
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (badges.isEmpty) const Text('No badges yet.'),
                  for (final b in badges)
                    Chip(
                      avatar: const Icon(Icons.military_tech, size: 16),
                      label: Text(badgeLabel(b)),
                    ),
                ],
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(note!),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('progress-rebuild'),
            onPressed: () async {
              final r = await onRebuild();
              set(() => note = r);
            },
            child: const Text('Rebuild from saved rides'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}
