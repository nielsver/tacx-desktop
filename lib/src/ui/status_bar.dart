import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Always-visible bottom status bar (step 3) and link-health readout:
/// trainer + data rate / last-packet age, auto-reconnect countdown, control
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
    required this.link,
    required this.metrics,
  });

  final ConnectionSnapshot snap;
  final HrStrapStatus strap;
  final ValueListenable<RideStats> ride;

  /// Trainer data-link health (packets/s, last-packet age), polled at 4 Hz.
  final ValueListenable<LinkHealth> link;

  /// Live metrics, only for the trainer-relayed heart rate.
  final ValueListenable<TrainerMetrics> metrics;

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
    // Give-up is reported as state Error (reconnect.rs): say what to do.
    if (s.reconnectGaveUp) return 'Link lost · press Reconnect';
    final name = s.deviceName.trim();
    switch (s.state) {
      case ConnectionState.disconnected:
        return 'No trainer';
      case ConnectionState.scanning:
        return 'Scanning…';
      case ConnectionState.connecting:
        return name.isEmpty ? 'Connecting…' : 'Connecting $name…';
      case ConnectionState.reconnecting:
        return reconnectLabel(s);
      case ConnectionState.error:
        return name.isEmpty ? 'Trainer error' : '$name · error';
      case ConnectionState.connected:
        final proto = protocolLabel(s.protocol);
        return name.isEmpty ? proto : '$name · $proto';
    }
  }

  /// Visible auto-reconnect countdown: "Reconnecting KICKR in 3 s · 2/5".
  static String reconnectLabel(ConnectionSnapshot s) {
    final name = s.deviceName.trim();
    final who = name.isEmpty ? 'Reconnecting' : 'Reconnecting $name';
    if (s.reconnectGaveUp) return 'Link lost · press Reconnect';
    final when = s.reconnectInS > 0 ? ' in ${s.reconnectInS} s' : '…';
    final tries = s.reconnectMaxAttempts > 0
        ? ' · ${s.reconnectAttempt}/${s.reconnectMaxAttempts}'
        : '';
    return '$who$when$tries';
  }

  /// Link dot colour: green under 1.5 s since the last packet, amber up to
  /// 4 s, red beyond (thresholds live in Rust `link_health`).
  static Color linkColor(LinkLevel l) => switch (l) {
    LinkLevel.good => RideColors.ok,
    LinkLevel.stale => RideColors.warn,
    LinkLevel.lost => RideColors.danger,
    LinkLevel.noData => RideColors.textMuted,
  };

  /// "4.0/s · 0.3 s" (rate, last-packet age); "waiting for data" before the first.
  static String linkLabel(LinkHealth h) {
    final age = h.lastPacketAgeMs;
    if (age == null) return 'waiting for data';
    final rate = h.packetsPerS.toStringAsFixed(1);
    final a = age >= 60000
        ? '${age ~/ 60000} min'
        : '${(age / 1000).toStringAsFixed(1)} s';
    return '$rate/s · $a';
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

  /// HR value and its source: the strap wins; otherwise HR relayed by the
  /// trainer (FE-C / FTMS). Battery level is not exposed by the BLE layer yet.
  static String hrLabel(HrStrapStatus h, {int? trainerBpm}) {
    switch (h.state) {
      case HrStrapState.connected:
        return h.heartRateBpm == null
            ? 'HR — · strap'
            : 'HR ${h.heartRateBpm} · strap';
      case HrStrapState.connecting:
        return 'HR … · strap';
      case HrStrapState.error:
        return trainerBpm != null ? 'HR $trainerBpm · trainer' : 'HR error';
      case HrStrapState.disconnected:
        return trainerBpm != null ? 'HR $trainerBpm · trainer' : 'HR off';
    }
  }

  static Color hrColor(HrStrapState s, {bool trainerHr = false}) => switch (s) {
    HrStrapState.connected => RideColors.heart,
    HrStrapState.connecting => RideColors.warn,
    _ when trainerHr => RideColors.heart,
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
    final connected = snap.state == ConnectionState.connected;
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
              if (connected)
                ValueListenableBuilder<LinkHealth>(
                  valueListenable: link,
                  builder: (context, h, _) => _Dot(
                    key: const ValueKey('status-link-dot'),
                    color: linkColor(h.level),
                  ),
                )
              else
                _Dot(color: trainerColor(snap.state)),
              SizedBox(width: tk.xs + 2),
              Flexible(
                child: Text(
                  trainerLabel(snap),
                  key: const ValueKey('status-trainer'),
                ),
              ),
              if (connected) ...[
                SizedBox(width: tk.s),
                ValueListenableBuilder<LinkHealth>(
                  valueListenable: link,
                  builder: (context, h, _) => Text(
                    linkLabel(h),
                    key: const ValueKey('status-link'),
                    style: kTabular.copyWith(
                      color: h.level == LinkLevel.good
                          ? RideColors.textSecondary
                          : linkColor(h.level),
                    ),
                  ),
                ),
              ],
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
              ValueListenableBuilder<TrainerMetrics>(
                valueListenable: metrics,
                builder: (context, m, _) {
                  final tHr = connected ? m.heartRateBpm : null;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Dot(color: hrColor(strap.state, trainerHr: tHr != null)),
                      SizedBox(width: tk.xs + 2),
                      Text(
                        hrLabel(strap, trainerBpm: tHr),
                        key: const ValueKey('status-hr'),
                        style: kTabular,
                      ),
                    ],
                  );
                },
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
  const _Dot({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
