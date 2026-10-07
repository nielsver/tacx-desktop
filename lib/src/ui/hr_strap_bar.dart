import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Slim bar for a separate Bluetooth heart-rate strap (Heart Rate Service
/// 0x180D): search, pick, connect, disconnect. While the strap streams, its
/// bpm replaces any heart rate the trainer relays.
class HeartRateStrapBar extends StatelessWidget {
  const HeartRateStrapBar({
    super.key,
    required this.status,
    required this.straps,
    required this.selectedId,
    required this.searching,
    required this.onSearch,
    required this.onSelect,
    required this.onConnect,
    required this.onDisconnect,
    this.note,
  });

  final HrStrapStatus status;
  final List<DiscoveredDevice> straps;
  final String? selectedId;
  final bool searching;
  final VoidCallback onSearch;
  final ValueChanged<String> onSelect;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  /// Local message (scan result / scan error) shown when Rust has no detail.
  final String? note;

  String get _text {
    switch (status.state) {
      case HrStrapState.connected:
        final bpm = status.heartRateBpm;
        return bpm == null
            ? '${status.deviceName} · waiting for heart rate (wear the strap)'
            : '${status.deviceName} · $bpm bpm';
      case HrStrapState.connecting:
        return 'Connecting to heart-rate strap…';
      case HrStrapState.error:
      case HrStrapState.disconnected:
        if (searching) return 'Searching for heart-rate straps…';
        if (status.detail.isNotEmpty) return status.detail;
        if (note != null) return note!;
        if (straps.length == 1) return 'Found ${straps.first.name}';
        return 'No heart-rate strap — trainer HR is used when it relays one';
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => _bar(context, c.maxWidth >= 720),
    );
  }

  Widget _bar(BuildContext context, bool roomy) {
    final connected = status.state == HrStrapState.connected;
    final connecting = status.state == HrStrapState.connecting;
    final busy = searching || connecting;
    final pick = straps.any((d) => d.id == selectedId)
        ? selectedId
        : (straps.isEmpty ? null : straps.first.id);
    return Container(
      key: const ValueKey('hr-strap-bar'),
      height: 48,
      padding: const EdgeInsets.only(left: 12, right: 2),
      decoration: BoxDecoration(
        color: RideColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RideColors.border),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.favorite : Icons.favorite_border,
            size: 16,
            color: connected ? RideColors.heart : RideColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _text,
              key: const ValueKey('hr-strap-status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: status.state == HrStrapState.error
                    ? RideColors.warn
                    : RideColors.textPrimary,
                fontSize: RideType.body,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (!connected && !busy && pick != null) ...[
            if (roomy && straps.length > 1)
              DropdownButton<String>(
                key: const ValueKey('hr-strap-picker'),
                value: pick,
                underline: const SizedBox.shrink(),
                dropdownColor: RideColors.surfaceHigh,
                style: const TextStyle(
                  color: RideColors.textPrimary,
                  fontSize: RideType.body,
                ),
                items: [
                  for (final d in straps)
                    DropdownMenuItem(value: d.id, child: Text(d.name)),
                ],
                onChanged: (id) {
                  if (id != null) onSelect(id);
                },
              ),
            TextButton.icon(
              key: const ValueKey('hr-strap-connect'),
              onPressed: onConnect,
              style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
              icon: const Icon(Icons.link, size: 16),
              label: const Text('Connect strap'),
            ),
          ],
          if (connected)
            TextButton.icon(
              key: const ValueKey('hr-strap-disconnect'),
              onPressed: onDisconnect,
              style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
              icon: const Icon(Icons.link_off, size: 16),
              label: const Text('Disconnect strap'),
            )
          else
            Tooltip(
              message:
                  'Search for a Bluetooth chest strap (Garmin HRM, Polar H9/H10, Wahoo TICKR…)',
              child: TextButton.icon(
                key: const ValueKey('hr-strap-search'),
                onPressed: busy ? null : onSearch,
                style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
                icon: const Icon(Icons.search, size: 16),
                label: Text(straps.isEmpty ? 'Find HR strap' : 'Search again'),
              ),
            ),
        ],
      ),
    );
  }
}
