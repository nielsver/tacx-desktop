import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/trainer/types.dart';

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
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    api.setDemoMode(enabled: true);
    _refresh();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _metrics = api.getMetrics();
      _snap = api.getConnectionSnapshot();
      _resRange = api.getResistanceRange();
      _interval = api.getIntervalStatus();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
  }

  Future<void> _scan() async {
    await _run(() async {
      final list = await api.scanTrainers(timeoutMs: 8000);
      setState(() {
        _devices = list;
        if (list.isNotEmpty) {
          _selected ??= list.first;
          if (!_devices.any((d) => d.id == _selected?.id)) {
            _selected = list.first;
          }
        }
      });
    });
  }

  Future<void> _connect() async {
    await _run(() async {
      await api.connectTrainer(deviceId: _selected?.id);
      setState(() {
        _resRange = api.getResistanceRange();
        _resistancePct = _resistancePct.clamp(_resRange.minPct, _resRange.maxPct);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = _snap.state == ConnectionState.connected;
    final theme = Theme.of(context);

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
                });
                _refresh();
              },
            ),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!, style: const TextStyle(color: Colors.white)),
                backgroundColor: theme.colorScheme.error.withValues(alpha: 0.9),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('Dismiss', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  children: [
                    _ConnectionBar(
                      devices: _devices,
                      selected: _selected,
                      busy: _busy,
                      connected: connected,
                      onSelect: (d) => setState(() => _selected = d),
                      onScan: _scan,
                      onConnect: _connect,
                      onDisconnect: () => _run(() => api.disconnectTrainer()),
                    ),
                    const SizedBox(height: 12),
                    _MetricsRow(metrics: _metrics, snap: _snap),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _ErgPanel(
                              targetWatts: _targetWatts,
                              step: _ergStep,
                              enabled: connected,
                              onStep: (s) => setState(() => _ergStep = s),
                              onNudge: (d) => setState(
                                () => _targetWatts = (_targetWatts + d * _ergStep).clamp(0, 2000),
                              ),
                              onApply: () => _run(
                                () => api.setTargetPower(watts: _targetWatts),
                              ),
                              onSetExact: (w) {
                                setState(() => _targetWatts = w);
                                _run(() => api.setTargetPower(watts: w));
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _ResistancePanel(
                              percent: _resistancePct,
                              range: _resRange,
                              enabled: connected,
                              onChanged: (v) => setState(() => _resistancePct = v),
                              onApply: () => _run(
                                () => api.setResistancePercent(percent: _resistancePct),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _IntervalPanel(
                              presets: _presets,
                              status: _interval,
                              enabled: connected,
                              onStart: (key) => _run(() => api.startInterval(key: key)),
                              onStop: () {
                                api.stopInterval();
                                _refresh();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Only one BLE client can control the trainer. Close Zwift / Tacx Training / '
                      'MyWhoosh / TrainerRoad before connecting. FTMS is preferred; older Tacx '
                      'trainers fall back to FE-C-over-BLE automatically.',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF00838F)],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.pedal_bike, size: 28),
          const SizedBox(width: 10),
          const Text(
            'Tacx Desktop',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          if (demo)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFC62828),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('DEMO', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          const Spacer(),
          Text(
            _protocolLabel(snap.protocol),
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(width: 16),
          Row(
            children: [
              const Text('Demo'),
              Switch(value: demo, onChanged: onDemoChanged),
            ],
          ),
        ],
      ),
    );
  }

  String _protocolLabel(ProtocolKind p) {
    switch (p) {
      case ProtocolKind.demo:
        return 'Protocol: Demo';
      case ProtocolKind.ftms:
        return 'Protocol: FTMS';
      case ProtocolKind.tacxFecBle:
        return 'Protocol: Tacx FE-C BLE';
    }
  }
}

class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({
    required this.devices,
    required this.selected,
    required this.busy,
    required this.connected,
    required this.onSelect,
    required this.onScan,
    required this.onConnect,
    required this.onDisconnect,
  });

  final List<DiscoveredDevice> devices;
  final DiscoveredDevice? selected;
  final bool busy;
  final bool connected;
  final ValueChanged<DiscoveredDevice?> onSelect;
  final VoidCallback onScan;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final snap = api.getConnectionSnapshot();
    return Card(
      color: const Color(0xFF151A22),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${_stateLabel(snap.state)}${snap.detail.isEmpty ? '' : ': ${snap.detail}'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 280,
              child: DropdownButtonFormField<DiscoveredDevice>(
                initialValue: selected != null && devices.any((d) => d.id == selected!.id)
                    ? devices.firstWhere((d) => d.id == selected!.id)
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'Trainer',
                ),
                items: devices
                    .map(
                      (d) => DropdownMenuItem(
                        value: d,
                        child: Text(
                          '${d.name} [${d.protocolHint}]',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: connected ? null : onSelect,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: busy ? null : onScan,
              child: const Text('Scan'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy || connected ? null : onConnect,
              child: const Text('Connect'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: busy || !connected ? null : onDisconnect,
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }

  String _stateLabel(ConnectionState s) {
    switch (s) {
      case ConnectionState.disconnected:
        return 'Disconnected';
      case ConnectionState.scanning:
        return 'Scanning';
      case ConnectionState.connecting:
        return 'Connecting';
      case ConnectionState.connected:
        return 'Connected';
      case ConnectionState.error:
        return 'Error';
    }
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
    return Row(
      children: [
        _MetricCard(label: 'Power', value: '${metrics.powerW.toStringAsFixed(0)} W', accent: const Color(0xFFFF7043)),
        const SizedBox(width: 10),
        _MetricCard(label: 'Cadence', value: '${metrics.cadenceRpm.toStringAsFixed(0)} rpm', accent: const Color(0xFF66BB6A)),
        const SizedBox(width: 10),
        _MetricCard(label: 'Speed', value: '${metrics.speedKmh.toStringAsFixed(1)} km/h', accent: const Color(0xFF42A5F5)),
        const SizedBox(width: 10),
        _MetricCard(label: 'Control', value: control, accent: const Color(0xFFAB47BC)),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.accent});

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF151A22),
          borderRadius: BorderRadius.circular(14),
          border: Border(left: BorderSide(color: accent, width: 4)),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: accent.withValues(alpha: 0.9), fontSize: 13)),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _ErgPanel extends StatefulWidget {
  const _ErgPanel({
    required this.targetWatts,
    required this.step,
    required this.enabled,
    required this.onStep,
    required this.onNudge,
    required this.onApply,
    required this.onSetExact,
  });

  final int targetWatts;
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
    return _Panel(
      title: 'ERG mode',
      child: Column(
        children: [
          Text('${widget.targetWatts} W', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
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
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton(onPressed: widget.enabled ? () => widget.onNudge(-1) : null, child: const Text('−')),
              const SizedBox(width: 12),
              FilledButton(onPressed: widget.enabled ? () => widget.onNudge(1) : null, child: const Text('+')),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: widget.enabled ? widget.onApply : null,
            child: const Text('Apply ERG'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  enabled: widget.enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Watts',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: widget.enabled
                    ? () {
                        final w = int.tryParse(_ctrl.text.trim());
                        if (w != null) widget.onSetExact(w.clamp(0, 2000));
                      }
                    : null,
                child: const Text('Set'),
              ),
            ],
          ),
        ],
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
  });

  final double percent;
  final ResistanceRange range;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final steps = ((range.maxPct - range.minPct) / (range.stepPct <= 0 ? 1 : range.stepPct))
        .round()
        .clamp(1, 1000);
    return _Panel(
      title: 'Resistance',
      child: Column(
        children: [
          Text('${percent.toStringAsFixed(0)} %', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
          Slider(
            value: percent.clamp(range.minPct, range.maxPct),
            min: range.minPct,
            max: range.maxPct,
            divisions: steps,
            label: '${percent.toStringAsFixed(0)}%',
            onChanged: enabled ? onChanged : null,
          ),
          Text(
            'Range ${range.minPct.toStringAsFixed(0)}–${range.maxPct.toStringAsFixed(0)}% '
            '(step ${range.stepPct.toStringAsFixed(1)})',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Text(
            'FTMS: Supported Resistance Level Range when available.\n'
            'FE-C fallback: basic resistance 0–200 N mapped from %.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const Spacer(),
          FilledButton(
            onPressed: enabled ? onApply : null,
            child: const Text('Apply Resistance'),
          ),
        ],
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
          Text(status.statusText, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final p in presets) ...[
                  FilledButton.tonal(
                    onPressed: enabled ? () => onStart(p.key) : null,
                    child: Text(p.label),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, top: 2),
                    child: Text(
                      '${p.workWatts}W / ${p.restWatts}W — ${p.description}',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ),
                ],
              ],
            ),
          ),
          OutlinedButton(onPressed: enabled ? onStop : null, child: const Text('Stop intervals')),
        ],
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
      color: const Color(0xFF151A22),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
