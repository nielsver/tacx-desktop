import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Always-visible bottom status bar (step 3): trainer, protocol, control
/// mode, HR strap, recording state and ride clock. (The DEMO chip lives in
/// the header; here Demo shows as "Demo trainer".)
///
/// The bar itself only rebuilds when the connection / strap state changes
/// (the dashboard already rebuilds then); the 1 Hz clock listens to [ride]
/// on its own so the rest of the bar never repaints with it.
class RideStatusBar extends StatelessWidget {
  const RideStatusBar({
    super.key,
    required this.snap,
    required this.strap,
    required this.ride,
  });

  final ConnectionSnapshot snap;
  final HrStrapStatus strap;
  final ValueListenable<RideStats> ride;

  static const double height = 28;

  /// Dot colour for a trainer connection state.
  static Color trainerColor(ConnectionState s) => switch (s) {
    ConnectionState.connected => RideColors.ok,
    ConnectionState.connecting ||
    ConnectionState.scanning ||
    ConnectionState.reconnecting => RideColors.warn,
    ConnectionState.error => RideColors.danger,
    ConnectionState.disconnected => RideColors.textMuted,
  };

  /// "KICKR CORE 1A2B · FTMS", "Demo trainer", "Reconnecting…", "No trainer".
  static String trainerLabel(ConnectionSnapshot s) {
    if (s.isDemo) return 'Demo trainer';
    final name = s.deviceName.trim();
    switch (s.state) {
      case ConnectionState.disconnected:
        return 'No trainer';
      case ConnectionState.scanning:
        return 'Scanning…';
      case ConnectionState.connecting:
        return name.isEmpty ? 'Connecting…' : 'Connecting $name…';
      case ConnectionState.reconnecting:
        return name.isEmpty ? 'Reconnecting…' : 'Reconnecting $name…';
      case ConnectionState.error:
        return name.isEmpty ? 'Trainer error' : '$name · error';
      case ConnectionState.connected:
        final proto = protocolLabel(s.protocol);
        return name.isEmpty ? proto : '$name · $proto';
    }
  }

  static String protocolLabel(ProtocolKind p) => switch (p) {
    ProtocolKind.ftms => 'FTMS',
    ProtocolKind.tacxFecBle => 'FE-C',
    ProtocolKind.demo => 'Demo',
  };

  /// Control mode while connected; `null` hides the chip.
  static String? modeLabel(ConnectionSnapshot s) {
    if (s.state != ConnectionState.connected) return null;
    return switch (s.mode) {
      ControlMode.erg => 'ERG',
      ControlMode.simulation => 'SIM',
      ControlMode.resistance => 'RES',
      ControlMode.idle => 'Free ride',
    };
  }

  static String hrLabel(HrStrapStatus h) => switch (h.state) {
    HrStrapState.connected =>
      h.heartRateBpm == null ? 'HR —' : 'HR ${h.heartRateBpm}',
    HrStrapState.connecting => 'HR …',
    HrStrapState.error => 'HR error',
    HrStrapState.disconnected => 'HR off',
  };

  static Color hrColor(HrStrapState s) => switch (s) {
    HrStrapState.connected => RideColors.heart,
    HrStrapState.connecting => RideColors.warn,
    HrStrapState.error => RideColors.danger,
    HrStrapState.disconnected => RideColors.textMuted,
  };

  static String clock(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600;
    final mm = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    const text = TextStyle(fontSize: 12, color: RideColors.textSecondary);
    final mode = modeLabel(snap);
    final gap = SizedBox(width: tk.l);
    return Semantics(
      container: true,
      label: 'Status bar',
      child: Container(
        key: const ValueKey('status-bar'),
        height: height,
        padding: EdgeInsets.symmetric(horizontal: tk.m),
        decoration: const BoxDecoration(
          color: RideColors.surface,
          border: Border(top: BorderSide(color: RideColors.border)),
        ),
        child: DefaultTextStyle.merge(
          style: text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: Row(
            children: [
              _Dot(color: trainerColor(snap.state)),
              SizedBox(width: tk.xs + 2),
              Flexible(
                child: Text(
                  trainerLabel(snap),
                  key: const ValueKey('status-trainer'),
                ),
              ),
              if (mode != null) ...[
                gap,
                Text(
                  mode,
                  key: const ValueKey('status-mode'),
                  style: const TextStyle(
                    color: RideColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              gap,
              _Dot(color: hrColor(strap.state)),
              SizedBox(width: tk.xs + 2),
              Text(
                hrLabel(strap),
                key: const ValueKey('status-hr'),
                style: kTabular,
              ),
              const Spacer(),
              ValueListenableBuilder<RideStats>(
                valueListenable: ride,
                builder: (context, r, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dot(
                      color: r.recording
                          ? RideColors.danger
                          : RideColors.textMuted,
                    ),
                    SizedBox(width: tk.xs + 2),
                    Text(
                      r.recording ? 'REC' : 'Not recording',
                      key: const ValueKey('status-rec'),
                    ),
                    gap,
                    Text(
                      clock(r.elapsedS),
                      key: const ValueKey('status-clock'),
                      style: kTabular.copyWith(color: RideColors.textPrimary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
