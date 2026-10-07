import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/ui/mode_copy.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// First-run welcome: mode cards + Connect trainer / Try Demo (P0-WEL1).
class WelcomePage extends StatelessWidget {
  const WelcomePage({
    super.key,
    required this.onConnectTrainer,
    required this.onTryDemo,
    this.onSkip,
  });

  final VoidCallback onConnectTrainer;
  final VoidCallback onTryDemo;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('welcome-page'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              children: [
                Row(
                  children: [
                    const Icon(Icons.pedal_bike, size: 32, color: Colors.white),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Welcome to Tacx Desktop',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: RideColors.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (onSkip != null)
                      TextButton(
                        key: const ValueKey('welcome-skip'),
                        onPressed: onSkip,
                        child: const Text('Skip'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Choose how you’ll ride. Connect a real trainer for live watts, or try Demo to explore the UI without hardware.',
                  style: TextStyle(
                    fontSize: RideType.body,
                    height: 1.4,
                    color: RideColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                const ModeCardsGrid(),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('welcome-connect'),
                      onPressed: onConnectTrainer,
                      icon: const Icon(Icons.bluetooth_connected),
                      label: const Text('Connect trainer'),
                    ),
                    FilledButton.tonalIcon(
                      key: const ValueKey('welcome-try-demo'),
                      onPressed: onTryDemo,
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Try Demo'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Demo metrics are simulated — turn Demo off before a real ride.',
                  style: TextStyle(
                    fontSize: RideType.caption,
                    color: RideColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
