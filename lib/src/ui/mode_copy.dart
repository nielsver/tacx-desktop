import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Paste-ready mode blurbs for Welcome / Modes dialog (checklist P0-WEL1).
class RideModeInfo {
  const RideModeInfo({
    required this.title,
    required this.body,
    required this.icon,
  });

  final String title;
  final String body;
  final IconData icon;

  static const all = <RideModeInfo>[
    RideModeInfo(
      title: 'Normal',
      body:
          'Full ride dashboard: metrics, ERG/Resistance/Simulation, intervals, and HR. Best when setting up or changing targets.',
      icon: Icons.dashboard_outlined,
    ),
    RideModeInfo(
      title: 'Focus',
      body:
          'Immersive dark view — big power, minimal chrome. Press G (or Focus) mid-ride; F11 for fullscreen.',
      icon: Icons.sports_esports_outlined,
    ),
    RideModeInfo(
      title: 'ERG',
      body:
          'Trainer holds a target wattage. Set watts, Apply — expect a few seconds to settle (esp. Kickr).',
      icon: Icons.bolt_outlined,
    ),
    RideModeInfo(
      title: 'Resistance',
      body:
          'Manual % load (level), not watts. Disabled when the trainer doesn’t advertise resistance (e.g. some Kickr Bike).',
      icon: Icons.tune,
    ),
    RideModeInfo(
      title: 'Simulation',
      body:
          'Grade / wind / Crr / Cw — outdoor-like load via FTMS sim or FE-C track resistance. Greyed if unsupported.',
      icon: Icons.terrain_outlined,
    ),
    RideModeInfo(
      title: 'Workouts',
      body:
          'Timed steps (ERG/ramp/…) and later GPX→grade. Setup outside Focus; ride immersive. Built-ins expand from today’s 3 presets.',
      icon: Icons.fitness_center_outlined,
    ),
    RideModeInfo(
      title: 'Demo',
      body:
          'Fake trainer to explore UI with no hardware. Metrics are simulated — turn Demo off before a real ride.',
      icon: Icons.science_outlined,
    ),
  ];
}

/// Wrap of mode cards (Welcome page + Modes dialog) — intrinsic height, no overflow.
class ModeCardsGrid extends StatelessWidget {
  const ModeCardsGrid({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 900
            ? 3
            : box.maxWidth >= 560
                ? 2
                : 1;
        final gap = 10.0;
        final width = cols == 1
            ? box.maxWidth
            : (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final m in RideModeInfo.all)
              SizedBox(
                width: width,
                child: Card(
                  key: ValueKey('mode-card-${m.title.toLowerCase()}'),
                  child: Padding(
                    padding: EdgeInsets.all(compact ? 12 : 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(m.icon, color: RideColors.accent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                m.title,
                                style: const TextStyle(
                                  fontSize: RideType.title,
                                  fontWeight: FontWeight.w700,
                                  color: RideColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                m.body,
                                style: const TextStyle(
                                  fontSize: RideType.label,
                                  height: 1.35,
                                  color: RideColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

Future<void> showModesDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: RideColors.surface,
      title: const Text('Ride modes'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: ModeCardsGrid(compact: true),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
