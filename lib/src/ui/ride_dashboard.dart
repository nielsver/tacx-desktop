import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});

  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  Timer? _poll;
  List<DiscoveredDevice> _devices = [];
  DiscoveredDevice? _selected;
  TrainerMetrics _metrics = const TrainerMetrics(
    powerW: 0,
    cadenceRpm: 0,
    speedKmh: 0,
  );
  ConnectionSnapshot _snap = const ConnectionSnapshot(
    state: ConnectionState.disconnected,
    detail: '',
    protocol: ProtocolKind.demo,
    isDemo: true,
    mode: ControlMode.idle,
    deviceName: '',
    supportsSimulation: true,
    reconnectAttempt: 0,
    reconnectMaxAttempts: 0,
    reconnectInS: 0,
    reconnectGaveUp: false,
  );
  ResistanceRange _resRange = const ResistanceRange(
    minPct: 0,
    maxPct: 100,
    stepPct: 1,
  );
  IntervalStatus _interval = const IntervalStatus(
    running: false,
    phase: 'Idle',
    statusText: 'Idle',
    repeatIndex: 0,
    remainingS: 0,
  );
  final _presets = api.listIntervalPresets();

  int _targetWatts = 150;
  int _ergStep = 10;
  double _resistancePct = 20;
  double _gradePct = 0;
  double _windKmh = 0;
  double _crr = 0.004;
  double _cw = 0.51;
  double _userWeightKg = 75;
  final double _bikeWeightKg = 8;
  final double _wheelDiameterM = 0.7;
  bool _busy = false;

  /// What the in-flight [_run] action is doing, shown next to the spinner
  /// so progress is never an unlabeled bar (P1-S5).
  String? _busyLabel;
  bool _resAutoApply = true;
  bool _didScan = false;
  String? _error;
  BluetoothStatus? _bt;
  bool _simExpanded = false;
  bool _simAdvanced = false;

  @override
  void initState() {
    super.initState();
    api.setDemoMode(enabled: true);
    _refresh();
    _checkBluetooth();
    _poll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final wasReconnecting = _snap.state == ConnectionState.reconnecting;
    setState(() {
      _metrics = api.getMetrics();
      _snap = api.getConnectionSnapshot();
      _resRange = api.getResistanceRange();
      _interval = api.getIntervalStatus();
      if (_snap.mode == ControlMode.simulation) {
        _simExpanded = true;
      }
    });
    if (wasReconnecting && _snap.state == ConnectionState.connected) {
      _toast('Trainer reconnected — previous target restored', Icons.link);
    }
  }

  Future<void> _checkBluetooth() async {
    try {
      final st = await api.bluetoothStatus();
      if (mounted) setState(() => _bt = st);
    } catch (_) {
      if (mounted) setState(() => _bt = null);
    }
  }

  bool get _canScan => _bt?.canScan ?? true;

  bool get _permissionDenied {
    if (_snap.isDemo) return false;
    // No BluetoothRadio.unauthorized in FRB; classify from hint + scan errors
    // (distinct from BT-off / noAdapter).
    final hint = (_bt?.hint ?? '').toLowerCase();
    final err = (_error ?? '').toLowerCase();
    final looksDenied =
        hint.contains('permission') ||
        hint.contains('not authorized') ||
        hint.contains('denied') ||
        hint.contains('tcc') ||
        hint.contains('privacy') ||
        err.contains('permission') ||
        err.contains('not authorized') ||
        err.contains('denied') ||
        err.contains('tcc') ||
        err.contains('privacy');
    if (!looksDenied) return false;
    final radio = _bt?.radio;
    if (radio == BluetoothRadio.off || radio == BluetoothRadio.noAdapter) {
      return false;
    }
    return true;
  }

  bool get _btRadioBad {
    if (_snap.isDemo || _bt == null) return false;
    return _bt!.radio == BluetoothRadio.off ||
        _bt!.radio == BluetoothRadio.noAdapter;
  }

  /// Runs a trainer action with busy/error handling. When [success] is given
  /// and the action completes, a short confirmation snackbar tells the rider
  /// the write was sent (P1-SIM3 apply feedback).
  Future<void> _run(
    Future<void> Function() action, {
    String? success,
    IconData successIcon = Icons.check_circle_outline,
    String label = 'Sending',
  }) async {
    // P1-X5: block double-submit while a write is already in flight.
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _error = null;
    });
    try {
      await action();
      if (success != null && mounted) _toast(success, successIcon);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
        _refresh();
      }
    }
  }

  /// Sends the current resistance level. Used by the Apply button and, when
  /// auto-apply is on, once when the slider is released (never per tick).
  Future<void> _applyResistance() => _run(
    () => api.setResistancePercent(percent: _resistancePct),
    success: 'Resistance ${_resistancePct.toStringAsFixed(0)} % sent',
    successIcon: Icons.tune,
  );

  void _toast(String message, IconData icon) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          width: 420,
          duration: const Duration(milliseconds: 1800),
          backgroundColor: const Color(0xFF1E2633),
          content: Row(
            children: [
              Icon(icon, size: 18, color: RideColors.ok),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: RideType.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _scan() async {
    await _checkBluetooth();
    if (!_canScan && !_snap.isDemo) return;
    await _run(() async {
      final list = await api.scanTrainers(timeoutMs: 8000);
      setState(() {
        _didScan = true;
        _devices = list;
        if (list.isNotEmpty) {
          _selected ??= list.first;
          if (!_devices.any((d) => d.id == _selected?.id)) {
            _selected = list.first;
          }
        } else {
          _selected = null;
        }
      });
    }, label: 'Scanning');
  }

  Future<void> _connect() async {
    await _run(() async {
      await api.connectTrainer(deviceId: _selected?.id);
      setState(() {
        _resRange = api.getResistanceRange();
        _resistancePct = _resistancePct.clamp(
          _resRange.minPct,
          _resRange.maxPct,
        );
      });
    }, label: 'Connecting');
  }

  @override
  Widget build(BuildContext context) {
    final connected = _snap.state == ConnectionState.connected;
    final theme = Theme.of(context);
    final simSupported = _snap.supportsSimulation || _snap.isDemo;
    final activeMode = _snap.mode;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              snap: _snap,
              demo: _snap.isDemo,
              onDemoChanged: (v) {
                api.setDemoMode(enabled: v);
                setState(() {
                  _devices = [];
                  _selected = null;
                  _error = null;
                  _didScan = false;
                });
                _refresh();
                _checkBluetooth();
              },
            ),
            if (_btRadioBad)
              _StatusStrip(
                key: const ValueKey('bt-off-banner'),
                icon: Icons.bluetooth_disabled,
                color: RideColors.bannerInfo,
                message: _bt!.hint,
                actions: [
                  TextButton(
                    onPressed: _checkBluetooth,
                    child: const Text(
                      'Check again',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      api.setDemoMode(enabled: true);
                      _refresh();
                      _checkBluetooth();
                    },
                    child: const Text(
                      'Use demo',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            if (_error != null)
              _StatusStrip(
                icon: Icons.error_outline,
                color: RideColors.bannerError,
                message: _error!,
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text(
                      'Dismiss',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            if (ReconnectBanner.shows(_snap))
              ReconnectBanner(
                snap: _snap,
                busy: _busy,
                onReconnect: () =>
                    _run(() => api.reconnectTrainer(), label: 'Reconnecting'),
                onDisconnect: () =>
                    _run(() => api.disconnectTrainer(), label: 'Disconnecting'),
              )
            else if (_error == null &&
                _snap.state == ConnectionState.error &&
                (_snap.detail.toLowerCase().contains('link lost') ||
                    _snap.detail.toLowerCase().contains('control lost')))
              _StatusStrip(
                icon: Icons.link_off,
                color: RideColors.bannerWarn,
                message: _snap.detail,
                actions: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => api.reconnectTrainer(),
                            label: 'Reconnecting',
                          ),
                    child: const Text(
                      'Reconnect',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: LayoutBuilder(
                  builder: (context, box) {
                    // Small windows (e.g. 1024x768 / 1280x720) cannot fit the
                    // control row once Simulation is open: switch to a
                    // scrolling column with a fixed-height control row.
                    final simOpen =
                        _simExpanded || activeMode == ControlMode.simulation;
                    final needed = simOpen
                        ? (_simAdvanced ? 900.0 : 780.0)
                        : 520.0;
                    final compact = box.maxHeight < needed;
                    final body = Column(
                      children: [
                        _ConnectionBar(
                          devices: _devices,
                          selected: _selected,
                          busy: _busy,
                          busyLabel: _busyLabel,
                          connected: connected,
                          snap: _snap,
                          canScan: _canScan || _snap.isDemo,
                          onSelect: (d) => setState(() => _selected = d),
                          onScan: _scan,
                          onConnect: _connect,
                          onReconnect: () => _run(
                            () => api.reconnectTrainer(),
                            label: 'Reconnecting',
                          ),
                          onDisconnect: () => _run(
                            () => api.disconnectTrainer(),
                            label: 'Disconnecting',
                          ),
                        ),
                        if (_permissionDenied && !connected) ...[
                          const SizedBox(height: 12),
                          _PermissionDeniedPanel(
                            onRetry: _checkBluetooth,
                            onUseDemo: () {
                              api.setDemoMode(enabled: true);
                              _refresh();
                              _checkBluetooth();
                            },
                          ),
                        ] else if (!_permissionDenied &&
                            !_btRadioBad &&
                            _didScan &&
                            _devices.isEmpty &&
                            !connected &&
                            !_busy) ...[
                          const SizedBox(height: 12),
                          _EmptyScanPanel(onScanAgain: _scan),
                        ],
                        const SizedBox(height: 12),
                        _MetricsRow(metrics: _metrics, snap: _snap),
                        const SizedBox(height: 12),
                        _FlexOrFixed(
                          key: const ValueKey('controls-row'),
                          fixed: compact,
                          height: 320,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Opacity(
                                  opacity:
                                      activeMode == ControlMode.erg ||
                                          activeMode == ControlMode.idle
                                      ? 1
                                      : 0.45,
                                  child: _ErgPanel(
                                    targetWatts: _targetWatts,
                                    liveTargetW: _metrics.targetPowerW,
                                    step: _ergStep,
                                    enabled: connected && !_busy,
                                    onStep: (s) => setState(() => _ergStep = s),
                                    onNudge: (d) => setState(
                                      () => _targetWatts =
                                          (_targetWatts + d * _ergStep).clamp(
                                            0,
                                            2000,
                                          ),
                                    ),
                                    onApply: () => _run(
                                      () => api.setTargetPower(
                                        watts: _targetWatts,
                                      ),
                                      success:
                                          'ERG target ${_targetWatts.round()} W sent',
                                      successIcon: Icons.bolt,
                                    ),
                                    onSetExact: (w) {
                                      setState(() => _targetWatts = w);
                                      _run(
                                        () => api.setTargetPower(watts: w),
                                        success:
                                            'ERG target ${w.round()} W sent',
                                        successIcon: Icons.bolt,
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Opacity(
                                  opacity:
                                      activeMode == ControlMode.resistance ||
                                          activeMode == ControlMode.idle
                                      ? 1
                                      : 0.45,
                                  child: _ResistancePanel(
                                    percent: _resistancePct,
                                    range: _resRange,
                                    enabled: connected && !_busy,
                                    onChanged: (v) =>
                                        setState(() => _resistancePct = v),
                                    onApply: _applyResistance,
                                    autoApply: _resAutoApply,
                                    onAutoApplyChanged: (v) =>
                                        setState(() => _resAutoApply = v),
                                    onChangeEnd: (v) {
                                      _resistancePct = v;
                                      if (_resAutoApply) _applyResistance();
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _IntervalPanel(
                                  presets: _presets,
                                  status: _interval,
                                  enabled: connected && !_busy,
                                  onStart: (key) => _run(
                                    () => api.startInterval(key: key),
                                    success: 'Interval started',
                                    successIcon: Icons.timer_outlined,
                                  ),
                                  onStop: () {
                                    api.stopInterval();
                                    _refresh();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _SimulationPanel(
                          key: const ValueKey('simulation-panel'),
                          expanded:
                              _simExpanded ||
                              activeMode == ControlMode.simulation,
                          advanced: _simAdvanced,
                          gradePct: _gradePct,
                          windKmh: _windKmh,
                          crr: _crr,
                          cw: _cw,
                          userWeightKg: _userWeightKg,
                          enabled: connected && simSupported && !_busy,
                          supportsSimulation: simSupported,
                          onToggleExpanded: () =>
                              setState(() => _simExpanded = !_simExpanded),
                          onToggleAdvanced: () =>
                              setState(() => _simAdvanced = !_simAdvanced),
                          onGrade: (v) => setState(() => _gradePct = v),
                          onWind: (v) => setState(() => _windKmh = v),
                          onCrr: (v) => setState(() => _crr = v),
                          onCw: (v) => setState(() => _cw = v),
                          onWeight: (v) => setState(() => _userWeightKg = v),
                          onApplySim: () => _run(
                            () async {
                              await api.setIndoorBikeSimulation(
                                windSpeedMps: _windKmh / 3.6,
                                gradePct: _gradePct,
                                crr: _crr,
                                cw: _cw,
                              );
                            },
                            success:
                                'Simulation sent · grade ${_gradePct.toStringAsFixed(1)} % · wind ${_windKmh.toStringAsFixed(0)} km/h',
                            successIcon: Icons.terrain,
                          ),
                          onApplyUser: () => _run(
                            () async {
                              await api.setUserConfiguration(
                                userWeightKg: _userWeightKg,
                                bicycleWeightKg: _bikeWeightKg,
                                wheelDiameterM: _wheelDiameterM,
                                gearRatio: 3.0,
                              );
                            },
                            success:
                                'Rider ${_userWeightKg.toStringAsFixed(0)} kg sent',
                            successIcon: Icons.person_outline,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Only one BLE client can control the trainer. Close Zwift / Tacx Training / '
                          'MyWhoosh / TrainerRoad before connecting. Windows: leave the trainer unpaired '
                          'in OS Bluetooth settings.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: RideColors.textMuted,
                            fontSize: RideType.footnote,
                          ),
                        ),
                      ],
                    );
                    if (!compact) return body;
                    return Scrollbar(
                      child: SingleChildScrollView(
                        key: const ValueKey('dashboard-scroll'),
                        padding: const EdgeInsets.only(right: 8),
                        child: body,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Expanded in a roomy window, fixed height when the dashboard scrolls.
class _FlexOrFixed extends StatelessWidget {
  const _FlexOrFixed({
    super.key,
    required this.fixed,
    required this.height,
    required this.child,
  });

  final bool fixed;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      fixed ? SizedBox(height: height, child: child) : Expanded(child: child);
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final Color color;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: RideType.label,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// P0-UX-4: automatic disconnect recovery progress ("reconnecting (2/4)…")
/// and the final gave-up state with the manual Reconnect action.
class ReconnectBanner extends StatelessWidget {
  const ReconnectBanner({
    super.key,
    required this.snap,
    required this.busy,
    required this.onReconnect,
    required this.onDisconnect,
  });

  final ConnectionSnapshot snap;
  final bool busy;
  final VoidCallback onReconnect;
  final VoidCallback onDisconnect;

  static bool isReconnecting(ConnectionSnapshot s) =>
      s.state == ConnectionState.reconnecting;

  static bool gaveUp(ConnectionSnapshot s) =>
      s.state == ConnectionState.error && s.reconnectGaveUp;

  static bool shows(ConnectionSnapshot s) => isReconnecting(s) || gaveUp(s);

  static String message(ConnectionSnapshot s) {
    if (gaveUp(s)) {
      return "Couldn't reconnect after ${s.reconnectAttempt} tries. "
          'Wake the trainer (pedal), then tap Reconnect.';
    }
    if (s.reconnectAttempt == 0) return 'Connection lost — reconnecting…';
    final n = '${s.reconnectAttempt}/${s.reconnectMaxAttempts}';
    return s.reconnectInS > 0
        ? 'Connection lost — reconnecting ($n) in ${s.reconnectInS} s…'
        : 'Connection lost — reconnecting ($n)…';
  }

  @override
  Widget build(BuildContext context) {
    const white = TextStyle(color: Colors.white);
    if (gaveUp(snap)) {
      return _StatusStrip(
        key: const ValueKey('reconnect-gave-up-banner'),
        icon: Icons.link_off,
        color: RideColors.bannerError,
        message: message(snap),
        actions: [
          TextButton(
            key: const ValueKey('reconnect-gave-up-action'),
            onPressed: busy ? null : onReconnect,
            child: const Text('Reconnect', style: white),
          ),
        ],
      );
    }
    // While an attempt is mid-connect only Disconnect is offered; a manual
    // Reconnect during the backoff wait skips the remaining delay.
    final waiting = snap.reconnectInS > 0;
    return _StatusStrip(
      key: const ValueKey('auto-reconnect-banner'),
      icon: Icons.sync,
      color: RideColors.bannerWarn,
      message: message(snap),
      actions: [
        TextButton(
          key: const ValueKey('reconnect-now-action'),
          onPressed: busy || !waiting ? null : onReconnect,
          child: Text(
            'Reconnect now',
            style: white.copyWith(
              color: busy || !waiting ? Colors.white70 : Colors.white,
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('reconnect-stop-action'),
          onPressed: busy ? null : onDisconnect,
          child: const Text('Disconnect', style: white),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.snap,
    required this.demo,
    required this.onDemoChanged,
  });

  final ConnectionSnapshot snap;
  final bool demo;
  final ValueChanged<bool> onDemoChanged;

  @override
  Widget build(BuildContext context) {
    final connected = snap.state == ConnectionState.connected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF00838F)],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.pedal_bike, size: 28, color: Colors.white),
          const SizedBox(width: 10),
          const Text(
            'Tacx Desktop',
            style: TextStyle(
              fontSize: RideType.header,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 12),
          if (demo)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: RideColors.demo,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'DEMO',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: RideType.caption,
                  letterSpacing: 0.6,
                  color: Colors.white,
                ),
              ),
            ),
          const SizedBox(width: 10),
          _ModeChip(mode: snap.mode),
          const Spacer(),
          if (connected && snap.deviceName.isNotEmpty)
            // Flexible so a long trainer name ellipsizes instead of
            // overflowing the header row on narrow windows.
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '${snap.deviceName} · ${_protocolShort(snap.protocol)}',
                  key: const ValueKey('header-identity'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: RideType.label,
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
          else
            Text(
              _protocolShort(snap.protocol),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: RideType.label,
              ),
            ),
          const SizedBox(width: 12),
          const Text('Demo', style: TextStyle(color: Colors.white)),
          Switch(value: demo, onChanged: onDemoChanged),
        ],
      ),
    );
  }

  String _protocolShort(ProtocolKind p) {
    switch (p) {
      case ProtocolKind.demo:
        return 'Demo';
      case ProtocolKind.ftms:
        return 'FTMS';
      case ProtocolKind.tacxFecBle:
        return 'FE-C';
    }
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});
  final ControlMode mode;

  @override
  Widget build(BuildContext context) {
    final label = switch (mode) {
      ControlMode.erg => 'ERG',
      ControlMode.resistance => 'Resistance',
      ControlMode.simulation => 'Simulation',
      ControlMode.idle => 'Idle',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: RideType.caption,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({
    required this.devices,
    required this.selected,
    required this.busy,
    this.busyLabel,
    required this.connected,
    required this.snap,
    required this.onSelect,
    required this.onScan,
    required this.canScan,
    required this.onConnect,
    required this.onReconnect,
    required this.onDisconnect,
  });

  final List<DiscoveredDevice> devices;
  final DiscoveredDevice? selected;
  final bool busy;
  final String? busyLabel;
  final bool connected;
  final ConnectionSnapshot snap;
  final ValueChanged<DiscoveredDevice?> onSelect;
  final VoidCallback onScan;
  final bool canScan;
  final VoidCallback onConnect;
  final VoidCallback onReconnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final reconnecting = snap.state == ConnectionState.reconnecting;
    // Mid-attempt (no countdown) a manual Reconnect would race the auto one.
    final canReconnect =
        !busy && !connected && !(reconnecting && snap.reconnectInS == 0);
    final inProgress =
        busy ||
        reconnecting ||
        snap.state == ConnectionState.scanning ||
        snap.state == ConnectionState.connecting;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (inProgress)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 140,
                    maxWidth: 320,
                  ),
                  child: ConnectionStatusIndicator(
                    state: snap.state,
                    detail: snap.detail,
                    busy: busy,
                    busyLabel: busyLabel,
                    reconnectAttempt: snap.reconnectAttempt,
                    reconnectMaxAttempts: snap.reconnectMaxAttempts,
                  ),
                ),
                SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<DiscoveredDevice>(
                    initialValue:
                        selected != null &&
                            devices.any((d) => d.id == selected!.id)
                        ? devices.firstWhere((d) => d.id == selected!.id)
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Trainer'),
                    items: devices
                        .map(
                          (d) => DropdownMenuItem(
                            value: d,
                            child: _DeviceRow(device: d),
                          ),
                        )
                        .toList(),
                    onChanged: connected ? null : onSelect,
                  ),
                ),
                FilledButton.tonal(
                  onPressed: (busy || !canScan) ? null : onScan,
                  child: const Text('Scan'),
                ),
                FilledButton(
                  onPressed: busy || connected || selected == null
                      ? null
                      : onConnect,
                  child: const Text('Connect'),
                ),
                FilledButton.tonal(
                  onPressed: canReconnect ? onReconnect : null,
                  child: const Text('Reconnect'),
                ),
                OutlinedButton(
                  // Disconnect also cancels a pending auto-reconnect.
                  onPressed: busy || !(connected || reconnecting)
                      ? null
                      : onDisconnect,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Connection state dot or spinner plus its label (P1-S5). Any in-progress
/// state (scanning, connecting, or a busy action) shows a spinner and a
/// matching label together; settled states show a coloured dot.
class ConnectionStatusIndicator extends StatelessWidget {
  const ConnectionStatusIndicator({
    super.key,
    required this.state,
    this.detail = '',
    this.busy = false,
    this.busyLabel,
    this.reconnectAttempt = 0,
    this.reconnectMaxAttempts = 0,
  });

  final ConnectionState state;
  final String detail;
  final bool busy;
  final String? busyLabel;

  /// Auto-reconnect attempt n of m (P0-UX-4); 0 when not reconnecting.
  final int reconnectAttempt;
  final int reconnectMaxAttempts;

  bool get inProgress =>
      busy ||
      state == ConnectionState.scanning ||
      state == ConnectionState.connecting ||
      state == ConnectionState.reconnecting;

  static String stateLabel(ConnectionState s) => switch (s) {
    ConnectionState.disconnected => 'Disconnected',
    ConnectionState.scanning => 'Scanning',
    ConnectionState.connecting => 'Connecting',
    ConnectionState.connected => 'Connected',
    ConnectionState.error => 'Error',
    ConnectionState.reconnecting => 'Reconnecting',
  };

  /// Label shown next to the dot/spinner.
  String get label {
    if (busy) return '${busyLabel ?? 'Working'}…';
    if (state == ConnectionState.reconnecting && reconnectAttempt > 0) {
      // The banner carries the full "connection lost" message.
      return 'Reconnecting ($reconnectAttempt/$reconnectMaxAttempts)…';
    }
    final base = stateLabel(state);
    final withEllipsis = inProgress ? '$base…' : base;
    return detail.isEmpty ? withEllipsis : '$withEllipsis · $detail';
  }

  Color get color {
    if (inProgress) return RideColors.warn;
    return switch (state) {
      ConnectionState.connected => RideColors.ok,
      ConnectionState.error => RideColors.warn,
      _ => RideColors.textSecondary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = color;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (inProgress)
          SizedBox(
            key: const ValueKey('connection-spinner'),
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c),
          )
        else
          Icon(
            Icons.circle,
            key: const ValueKey('connection-dot'),
            size: 10,
            color: c,
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            key: const ValueKey('connection-state-label'),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: RideType.label,
              color: c,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }
}

/// Scan-list row: name, protocol chip and RSSI signal bars.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device});

  final DiscoveredDevice device;

  static String protocolLabel(String hint) => switch (hint) {
    'ftms' => 'FTMS',
    'tacx_fec' => 'FE-C',
    _ => '?',
  };

  /// 0–4 bars from RSSI (dBm). Null RSSI → 0.
  static int bars(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -55) return 4;
    if (rssi >= -67) return 3;
    if (rssi >= -78) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final hint = device.protocolHint;
    final chipColor = switch (hint) {
      'ftms' => RideColors.accent,
      'tacx_fec' => RideColors.accentAlt,
      _ => RideColors.textMuted,
    };
    final n = bars(device.rssi);
    return Row(
      children: [
        Expanded(
          child: Text(
            device.name.isEmpty ? 'Unnamed trainer' : device.name,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: chipColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: chipColor.withValues(alpha: 0.6)),
          ),
          child: Text(
            protocolLabel(hint),
            style: TextStyle(
              fontSize: RideType.footnote,
              fontWeight: FontWeight.w700,
              color: chipColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: device.rssi == null
              ? 'Signal unknown'
              : 'Signal ${device.rssi} dBm',
          child: _SignalBars(bars: n),
        ),
      ],
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.bars});

  final int bars;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 3,
              height: 4.0 + i * 3.0,
              decoration: BoxDecoration(
                color: i < bars ? RideColors.ok : RideColors.border,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyScanPanel extends StatelessWidget {
  const _EmptyScanPanel({required this.onScanAgain});
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: RideColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.search_off,
                color: RideColors.textSecondary,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No trainers found',
                    style: TextStyle(
                      fontSize: RideType.title,
                      fontWeight: FontWeight.w700,
                      color: RideColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '• Quit Zwift / Tacx Training / MyWhoosh / TrainerRoad\n'
                    '• Wake the trainer and stand nearby\n'
                    '• Windows: leave the trainer unpaired in Bluetooth settings',
                    style: TextStyle(
                      fontSize: RideType.label,
                      height: 1.45,
                      color: RideColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: onScanAgain,
                    icon: const Icon(Icons.bluetooth_searching, size: 18),
                    label: const Text('Scan again'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionDeniedPanel extends StatelessWidget {
  const _PermissionDeniedPanel({
    required this.onRetry,
    required this.onUseDemo,
  });

  final VoidCallback onRetry;
  final VoidCallback onUseDemo;

  @override
  Widget build(BuildContext context) {
    final steps = switch (defaultTargetPlatform) {
      TargetPlatform.macOS =>
        'macOS: System Settings → Privacy & Security → Bluetooth → allow Tacx Desktop.',
      TargetPlatform.windows =>
        'Windows: Settings → Bluetooth & devices → ensure Bluetooth is on and app access is allowed.',
      TargetPlatform.linux =>
        'Linux: BlueZ running, D-Bus user session active, user in the bluetooth group.',
      _ =>
        'Allow Bluetooth permission for Tacx Desktop in your OS privacy settings.',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: RideColors.danger.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.lock_outline,
                color: RideColors.danger,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Bluetooth permission denied',
                    style: TextStyle(
                      fontSize: RideType.title,
                      fontWeight: FontWeight.w700,
                      color: RideColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    steps,
                    style: const TextStyle(
                      fontSize: RideType.label,
                      height: 1.45,
                      color: RideColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('Check again'),
                      ),
                      OutlinedButton(
                        onPressed: onUseDemo,
                        child: const Text('Use demo'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.metrics, required this.snap});

  final TrainerMetrics metrics;
  final ConnectionSnapshot snap;

  @override
  Widget build(BuildContext context) {
    String control;
    if (metrics.targetPowerW != null) {
      control = 'ERG ${metrics.targetPowerW!.toStringAsFixed(0)} W';
    } else if (metrics.resistancePct != null) {
      control = 'Res ${metrics.resistancePct!.toStringAsFixed(0)}%';
    } else {
      control = snap.mode.name.toUpperCase();
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: _MetricCard(
              label: 'Power',
              value: metrics.powerW.toStringAsFixed(0),
              unit: 'W',
              accent: RideColors.power,
              valueSize: RideType.hero,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MetricCard(
              label: 'Cadence',
              value: metrics.cadenceRpm.toStringAsFixed(0),
              unit: 'rpm',
              accent: RideColors.cadence,
              valueSize: RideType.metric,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MetricCard(
              label: 'Speed',
              value: metrics.speedKmh.toStringAsFixed(1),
              unit: 'km/h',
              accent: RideColors.speed,
              valueSize: RideType.metric,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MetricCard(
              label: 'Control',
              value: control,
              unit: '',
              accent: RideColors.control,
              valueSize: RideType.body,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.accent,
    required this.valueSize,
  });

  final String label;
  final String value;
  final String unit;
  final Color accent;
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('metric-${label.toLowerCase()}'),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
      decoration: BoxDecoration(
        color: RideColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: RideColors.border),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 0,
            spreadRadius: 0,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: accent.withValues(alpha: 0.95),
              fontSize: RideType.footnote,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: valueSize,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                    letterSpacing: -0.5,
                    color: RideColors.textPrimary,
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    unit,
                    style: const TextStyle(
                      fontSize: RideType.caption,
                      fontWeight: FontWeight.w600,
                      color: RideColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One-tap ERG targets (set + apply).
const _ergPresets = [100, 150, 200, 250];

class _ErgPanel extends StatefulWidget {
  const _ErgPanel({
    required this.targetWatts,
    required this.liveTargetW,
    required this.step,
    required this.enabled,
    required this.onStep,
    required this.onNudge,
    required this.onApply,
    required this.onSetExact,
  });

  final int targetWatts;
  final double? liveTargetW;
  final int step;
  final bool enabled;
  final ValueChanged<int> onStep;
  final ValueChanged<int> onNudge;
  final VoidCallback onApply;
  final ValueChanged<int> onSetExact;

  @override
  State<_ErgPanel> createState() => _ErgPanelState();
}

class _ErgPanelState extends State<_ErgPanel> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.liveTargetW?.round();
    final pending = live != null && live != widget.targetWatts;
    return _Panel(
      title: 'ERG mode',
      child: SingleChildScrollView(
        child: Column(
          children: [
            Text(
              '${widget.targetWatts}',
              style: const TextStyle(
                fontSize: RideType.target,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                height: 1,
              ),
            ),
            const Text(
              'W pending',
              style: TextStyle(
                fontSize: RideType.caption,
                color: RideColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (pending) ...[
              const SizedBox(height: 6),
              Text(
                'Trainer at ${live}W — tap Apply',
                style: const TextStyle(
                  fontSize: RideType.caption,
                  color: RideColors.warn,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ] else if (live != null) ...[
              const SizedBox(height: 6),
              Text(
                'Trainer at ${live}W',
                style: const TextStyle(
                  fontSize: RideType.caption,
                  color: RideColors.ok,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 5, label: Text('5')),
                ButtonSegment(value: 10, label: Text('10')),
                ButtonSegment(value: 25, label: Text('25')),
              ],
              selected: {widget.step},
              onSelectionChanged: widget.enabled
                  ? (s) => widget.onStep(s.first)
                  : null,
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in _ergPresets)
                  ActionChip(
                    key: ValueKey('erg-preset-$w'),
                    label: Text(
                      '${w}W',
                      style: TextStyle(
                        fontSize: RideType.label,
                        fontWeight: FontWeight.w700,
                        color: w == widget.targetWatts
                            ? RideColors.accent
                            : RideColors.textPrimary,
                      ),
                    ),
                    tooltip: 'Set and apply ${w}W',
                    side: BorderSide(
                      color: w == widget.targetWatts
                          ? RideColors.accent
                          : RideColors.border,
                    ),
                    onPressed: widget.enabled
                        ? () => widget.onSetExact(w)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: widget.enabled ? () => widget.onNudge(-1) : null,
                    child: const Text(
                      '−',
                      style: TextStyle(fontSize: RideType.glyph),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: widget.enabled ? () => widget.onNudge(1) : null,
                    child: const Text(
                      '+',
                      style: TextStyle(fontSize: RideType.glyph),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: widget.enabled ? widget.onApply : null,
                child: const Text('Apply ERG'),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    enabled: widget.enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Watts'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: widget.enabled
                      ? () {
                          final w = int.tryParse(_ctrl.text.trim());
                          if (w != null) {
                            widget.onSetExact(w.clamp(0, 2000));
                          }
                        }
                      : null,
                  child: const Text('Set'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResistancePanel extends StatelessWidget {
  const _ResistancePanel({
    required this.percent,
    required this.range,
    required this.enabled,
    required this.onChanged,
    required this.onApply,
    required this.autoApply,
    required this.onAutoApplyChanged,
    required this.onChangeEnd,
  });

  final double percent;
  final ResistanceRange range;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final VoidCallback onApply;
  final bool autoApply;
  final ValueChanged<bool> onAutoApplyChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final steps =
        ((range.maxPct - range.minPct) /
                (range.stepPct <= 0 ? 1 : range.stepPct))
            .round()
            .clamp(1, 1000);
    return _Panel(
      title: 'Resistance',
      child: SingleChildScrollView(
        child: Column(
          children: [
            Text(
              percent.toStringAsFixed(0),
              style: const TextStyle(
                fontSize: RideType.target,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                height: 1,
              ),
            ),
            const Text(
              '%',
              style: TextStyle(
                fontSize: RideType.caption,
                color: RideColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Slider(
              key: const ValueKey('resistance-slider'),
              value: percent.clamp(range.minPct, range.maxPct),
              min: range.minPct,
              max: range.maxPct,
              divisions: steps,
              label: '${percent.toStringAsFixed(0)}%',
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
            Text(
              'Range ${range.minPct.toStringAsFixed(0)}–${range.maxPct.toStringAsFixed(0)}% · step ${range.stepPct.toStringAsFixed(1)}',
              style: const TextStyle(
                color: RideColors.textSecondary,
                fontSize: RideType.caption,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Apply on release',
                      style: TextStyle(
                        color: RideColors.textSecondary,
                        fontSize: RideType.caption,
                      ),
                    ),
                  ),
                  Switch(
                    key: const ValueKey('resistance-auto-apply'),
                    value: autoApply,
                    onChanged: onAutoApplyChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: enabled ? onApply : null,
                child: const Text('Apply Resistance'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntervalPanel extends StatelessWidget {
  const _IntervalPanel({
    required this.presets,
    required this.status,
    required this.enabled,
    required this.onStart,
    required this.onStop,
  });

  final List<IntervalPresetInfo> presets;
  final IntervalStatus status;
  final bool enabled;
  final ValueChanged<String> onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Intervals',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            status.statusText,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: RideType.label,
              color: RideColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final p in presets) ...[
                  SizedBox(
                    height: 44,
                    child: FilledButton.tonal(
                      onPressed: enabled ? () => onStart(p.key) : null,
                      child: Text(p.label),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10, top: 4),
                    child: Text(
                      '${p.workWatts}W / ${p.restWatts}W — ${p.description}',
                      style: const TextStyle(
                        color: RideColors.textSecondary,
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
              onPressed: (enabled || status.running) ? onStop : null,
              child: const Text('Stop intervals'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SimulationPanel extends StatelessWidget {
  const _SimulationPanel({
    super.key,
    required this.expanded,
    required this.advanced,
    required this.gradePct,
    required this.windKmh,
    required this.crr,
    required this.cw,
    required this.userWeightKg,
    required this.enabled,
    required this.supportsSimulation,
    required this.onToggleExpanded,
    required this.onToggleAdvanced,
    required this.onGrade,
    required this.onWind,
    required this.onCrr,
    required this.onCw,
    required this.onWeight,
    required this.onApplySim,
    required this.onApplyUser,
  });

  final bool expanded;
  final bool advanced;
  final double gradePct;
  final double windKmh;
  final double crr;
  final double cw;
  final double userWeightKg;
  final bool enabled;
  final bool supportsSimulation;
  final VoidCallback onToggleExpanded;
  final VoidCallback onToggleAdvanced;
  final ValueChanged<double> onGrade;
  final ValueChanged<double> onWind;
  final ValueChanged<double> onCrr;
  final ValueChanged<double> onCw;
  final ValueChanged<double> onWeight;
  final VoidCallback onApplySim;
  final VoidCallback onApplyUser;

  @override
  Widget build(BuildContext context) {
    final active = supportsSimulation;
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: const ValueKey('simulation-header'),
                onTap: onToggleExpanded,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTapTarget),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                          color: RideColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Simulation',
                          style: TextStyle(
                            fontSize: RideType.title,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            supportsSimulation
                                ? 'Grade · wind · Crr/Cw'
                                : 'Not advertised on this trainer',
                            style: TextStyle(
                              color: supportsSimulation
                                  ? RideColors.textSecondary
                                  : RideColors.textMuted,
                              fontSize: RideType.caption,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        FilledButton(
                          onPressed: enabled ? onApplySim : null,
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (expanded) ...[
                const SizedBox(height: 8),
                Text(
                  'Grade ${gradePct.toStringAsFixed(1)} %',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: RideType.label,
                  ),
                ),
                Slider(
                  value: gradePct.clamp(-10.0, 15.0),
                  min: -10,
                  max: 15,
                  divisions: 250,
                  label: '${gradePct.toStringAsFixed(1)}%',
                  onChanged: enabled ? onGrade : null,
                ),
                Text(
                  'Wind ${windKmh.toStringAsFixed(0)} km/h',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: RideType.label,
                  ),
                ),
                Slider(
                  value: windKmh.clamp(-40.0, 40.0),
                  min: -40,
                  max: 40,
                  divisions: 80,
                  label: '${windKmh.toStringAsFixed(0)} km/h',
                  onChanged: enabled ? onWind : null,
                ),
                TextButton(
                  onPressed: onToggleAdvanced,
                  child: Text(
                    advanced ? 'Hide advanced' : 'Advanced (Crr / Cw / Rider)',
                  ),
                ),
                if (advanced) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Crr ${crr.toStringAsFixed(4)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: RideType.caption,
                              ),
                            ),
                            Slider(
                              value: crr.clamp(0.0, 0.0127),
                              min: 0,
                              max: 0.0127,
                              divisions: 127,
                              label: crr.toStringAsFixed(4),
                              onChanged: enabled ? onCrr : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Cw ${cw.toStringAsFixed(2)} kg/m',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: RideType.caption,
                              ),
                            ),
                            Slider(
                              value: cw.clamp(0.0, 1.86),
                              min: 0,
                              max: 1.86,
                              divisions: 186,
                              label: cw.toStringAsFixed(2),
                              onChanged: enabled ? onCw : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 180,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Rider ${userWeightKg.toStringAsFixed(0)} kg',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: RideType.caption,
                              ),
                            ),
                            Slider(
                              value: userWeightKg.clamp(40.0, 120.0),
                              min: 40,
                              max: 120,
                              divisions: 80,
                              label: '${userWeightKg.toStringAsFixed(0)} kg',
                              onChanged: enabled ? onWeight : null,
                            ),
                            FilledButton.tonal(
                              onPressed: enabled ? onApplyUser : null,
                              child: const Text('Apply user'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: RideType.title,
                fontWeight: FontWeight.w700,
                color: RideColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
