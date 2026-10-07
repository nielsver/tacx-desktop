import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Short first-run tips (checklist P0-TIP1). Not a BlueZ install novel.
abstract final class BluetoothTips {
  static List<String> bullets() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
        return const [
          'Forget the trainer in KDE Bluetooth — connect only in-app (no OS pair)',
          'Quit Zwift / Wahoo / Tacx Training / MyWhoosh / TrainerRoad / Rouvy',
          'User in the bluetooth group (log out/in after usermod) — never sudo the app',
          'rfkill unblock bluetooth + Plasma Bluetooth On if Scan is empty',
          'One controller only — close the Wahoo app if Kickr says control lost',
        ];
      case TargetPlatform.windows:
        return const [
          'Leave Kickr/Tacx unpaired in Windows Bluetooth — connect only in-app',
          'Quit Zwift / Wahoo / Tacx Training / MyWhoosh / TrainerRoad / Rouvy',
          'Wake the trainer and stand nearby',
        ];
      case TargetPlatform.macOS:
        return const [
          'Allow Bluetooth for Tacx Desktop; Forget device if OS-paired',
          'Quit Zwift / Tacx Training / MyWhoosh / TrainerRoad',
          'Wake the trainer and stand nearby',
        ];
      default:
        return const [
          'Leave the trainer unpaired in OS Bluetooth — connect only in-app',
          'Quit Zwift / Wahoo / Tacx Training / MyWhoosh / TrainerRoad',
          'Wake the trainer and stand nearby',
        ];
    }
  }

  /// Dense string used by the empty-scan panel on the ride dashboard.
  static String emptyScanText() =>
      bullets().map((b) => '• $b').join('\n');
}

class BluetoothTipsPanel extends StatelessWidget {
  const BluetoothTipsPanel({super.key, this.initiallyExpanded = false});

  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('bluetooth-tips'),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        title: Text(
          defaultTargetPlatform == TargetPlatform.linux
              ? 'Bluetooth tips (Garuda/Linux)'
              : 'Bluetooth tips',
          style: const TextStyle(
            fontSize: RideType.title,
            fontWeight: FontWeight.w700,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          for (final b in BluetoothTips.bullets())
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  ', style: TextStyle(color: RideColors.accent)),
                  Expanded(
                    child: Text(
                      b,
                      style: const TextStyle(
                        fontSize: RideType.label,
                        height: 1.4,
                        color: RideColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
