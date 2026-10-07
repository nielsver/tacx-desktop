import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/bluetooth_tips.dart';
import 'package:tacx_desktop/src/ui/mode_copy.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

/// Dedicated connect step: Scan → Connect trainer; HR optional; Start gated.
class ConnectPage extends StatefulWidget {
  const ConnectPage({
    super.key,
    required this.onStartRide,
    required this.onTryDemo,
  });

  final VoidCallback onStartRide;
  final VoidCallback onTryDemo;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  Timer? _poll;
  ConnectionSnapshot _snap = const ConnectionSnapshot(
    state: ConnectionState.disconnected,
    detail: '',
    protocol: ProtocolKind.ftms,
    isDemo: false,
    mode: ControlMode.idle,
    deviceName: '',
    supportsSimulation: false,
    reconnectAttempt: 0,
    reconnectMaxAttempts: 0,
    reconnectInS: 0,
    reconnectGaveUp: false,
  );
  BluetoothStatus? _bt;
  List<DiscoveredDevice> _devices = [];
  DiscoveredDevice? _selected;
  List<DiscoveredDevice> _straps = [];
  String? _strapPick;
  HrStrapStatus _strap = const HrStrapStatus(
    state: HrStrapState.disconnected,
    deviceId: '',
    deviceName: '',
    detail: '',
    heartRateBpm: null,
  );
  bool _busy = false;
  bool _scanningHr = false;
  bool _hrSkipped = false;
  String? _error;
  bool _didScan = false;

  bool get _connected => _snap.state == ConnectionState.connected;
  bool get _canStart => _connected || _snap.isDemo;
  bool get _canScan => (_bt?.canScan ?? true) || _snap.isDemo;

  @override
  void initState() {
    super.initState();
    _refresh();
    _checkBt();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final snap = api.getConnectionSnapshot();
    final strap = api.getHeartRateStrapStatus();
    setState(() {
      _snap = snap;
      _strap = strap;
    });
  }

  Future<void> _checkBt() async {
    try {
      final bt = await api.bluetoothStatus();
      if (mounted) setState(() => _bt = bt);
    } catch (_) {}
  }

  Future<void> _scan() async {
    await _checkBt();
    if (!_canScan) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await api.scanTrainers(timeoutMs: 8000);
      if (!mounted) return;
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
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.connectTrainer(deviceId: _selected?.id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await api.disconnectTrainer();
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _findHr() async {
    setState(() {
      _scanningHr = true;
      _hrSkipped = false;
    });
    try {
      final list = await api.scanHeartRateStraps(timeoutMs: 6000);
      if (!mounted) return;
      setState(() {
        _straps = list;
        _strapPick = list.isEmpty ? null : list.first.id;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _scanningHr = false);
      _refresh();
    }
  }

  Future<void> _connectHr() async {
    final id = _strapPick ?? (_straps.isEmpty ? null : _straps.first.id);
    if (id == null) return;
    try {
      await api.connectHeartRateStrap(deviceId: id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final startReason = _canStart
        ? null
        : 'Connect a trainer or enable Demo';

    return Scaffold(
      key: const ValueKey('connect-page'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth, color: RideColors.accent),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Connect',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: RideColors.textPrimary,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('connect-modes'),
                      onPressed: () => showModesDialog(context),
                      child: const Text('Modes'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Trainer required before the full ride. Heart-rate strap is optional.',
                  style: TextStyle(
                    fontSize: RideType.body,
                    color: RideColors.textSecondary,
                  ),
                ),
                if (_snap.isDemo) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('connect-demo-banner'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: RideColors.demo.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: RideColors.demo),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.science, color: RideColors.demo, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'DEMO — stub devices only. Metrics are simulated. Turn Demo off for a live ride.',
                            style: TextStyle(
                              fontSize: RideType.label,
                              fontWeight: FontWeight.w600,
                              color: RideColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _snap.isDemo
                              ? 'Demo trainers (not real hardware)'
                              : 'Trainer',
                          style: const TextStyle(
                            fontSize: RideType.title,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _snap.detail.isEmpty
                              ? (_connected
                                  ? _snap.deviceName
                                  : 'Scan for FTMS / Kickr / Tacx FE-C')
                              : _snap.detail,
                          style: const TextStyle(
                            fontSize: RideType.label,
                            color: RideColors.textSecondary,
                          ),
                        ),
                        if (_connected && _snap.deviceName.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            key: const ValueKey('connect-identity'),
                            '${_snap.deviceName} · ${_protocolLabel(_snap.protocol)}',
                            style: const TextStyle(
                              fontSize: RideType.body,
                              fontWeight: FontWeight.w600,
                              color: RideColors.ok,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        DropdownButtonFormField<DiscoveredDevice>(
                          initialValue: _selected != null &&
                                  _devices.any((d) => d.id == _selected!.id)
                              ? _devices
                                  .firstWhere((d) => d.id == _selected!.id)
                              : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: _snap.isDemo
                                ? 'Demo trainers'
                                : 'Trainer',
                          ),
                          items: _devices
                              .map(
                                (d) => DropdownMenuItem(
                                  value: d,
                                  child: Text(
                                    d.name.isEmpty ? d.id : d.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _connected || _busy
                              ? null
                              : (d) => setState(() => _selected = d),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonal(
                              key: const ValueKey('connect-scan'),
                              onPressed: _busy || !_canScan ? null : _scan,
                              child: const Text('Scan'),
                            ),
                            FilledButton(
                              key: const ValueKey('connect-connect'),
                              onPressed: _busy ||
                                      _connected ||
                                      _selected == null
                                  ? null
                                  : _connect,
                              child: const Text('Connect'),
                            ),
                            OutlinedButton(
                              onPressed: _busy || !_connected
                                  ? null
                                  : _disconnect,
                              child: const Text('Disconnect'),
                            ),
                            if (!_snap.isDemo)
                              TextButton(
                                key: const ValueKey('connect-use-demo'),
                                onPressed: _busy ? null : widget.onTryDemo,
                                child: const Text('Use demo'),
                              ),
                          ],
                        ),
                        if (_didScan &&
                            _devices.isEmpty &&
                            !_connected &&
                            !_busy) ...[
                          const SizedBox(height: 12),
                          Text(
                            BluetoothTips.emptyScanText(),
                            style: const TextStyle(
                              fontSize: RideType.label,
                              height: 1.4,
                              color: RideColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Heart-rate strap (optional)',
                          style: TextStyle(
                            fontSize: RideType.title,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Optional — trainer HR used if it relays one.',
                          style: TextStyle(
                            fontSize: RideType.label,
                            color: RideColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_straps.isNotEmpty)
                          DropdownButtonFormField<String>(
                            initialValue: _strapPick,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Strap',
                            ),
                            items: _straps
                                .map(
                                  (d) => DropdownMenuItem(
                                    value: d.id,
                                    child: Text(
                                      d.name.isEmpty ? d.id : d.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (id) =>
                                setState(() => _strapPick = id),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonal(
                              key: const ValueKey('connect-hr-find'),
                              onPressed: _scanningHr ? null : _findHr,
                              child: Text(
                                _scanningHr ? 'Searching…' : 'Find HR strap',
                              ),
                            ),
                            FilledButton(
                              key: const ValueKey('connect-hr-connect'),
                              onPressed: _strapPick == null ||
                                      _strap.state == HrStrapState.connected
                                  ? null
                                  : _connectHr,
                              child: const Text('Connect strap'),
                            ),
                            TextButton(
                              key: const ValueKey('connect-hr-skip'),
                              onPressed: () =>
                                  setState(() => _hrSkipped = true),
                              child: Text(
                                _hrSkipped ? 'HR skipped' : 'Skip',
                              ),
                            ),
                          ],
                        ),
                        if (_strap.state == HrStrapState.connected)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${_strap.deviceName} connected',
                              style: const TextStyle(color: RideColors.ok),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const BluetoothTipsPanel(initiallyExpanded: true),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: RideColors.danger),
                  ),
                ],
                const SizedBox(height: 20),
                Tooltip(
                  message: startReason ?? 'Enter the ride dashboard',
                  child: FilledButton.icon(
                    key: const ValueKey('connect-start-ride'),
                    onPressed: _canStart && !_busy ? widget.onStartRide : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start ride'),
                  ),
                ),
                if (!_canStart)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Connect a trainer or enable Demo to start.',
                      key: ValueKey('connect-gate-reason'),
                      style: TextStyle(
                        fontSize: RideType.caption,
                        color: RideColors.warn,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _protocolLabel(ProtocolKind p) => switch (p) {
        ProtocolKind.demo => 'Demo',
        ProtocolKind.ftms => 'FTMS',
        ProtocolKind.tacxFecBle => 'FE-C',
      };
}
