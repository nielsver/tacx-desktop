import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:flutter/services.dart';
import 'package:tacx_desktop/src/ride_prefs.dart';
import 'package:tacx_desktop/src/ui/focus_ride_view.dart';
import 'package:tacx_desktop/src/ui/hr_strap_bar.dart';
import 'package:tacx_desktop/src/ui/live_trend_chart.dart';
import 'package:tacx_desktop/src/ui/workout_panel.dart';
import 'package:tacx_desktop/src/ui/workout_ride_view.dart';
import 'package:tacx_desktop/src/workout/route_ghost.dart';
import 'package:tacx_desktop/src/workout/workout_plan.dart';
import 'package:tacx_desktop/src/ui/elev_profile_chart.dart'
    show ElevProfileChart, GhostDeltaChip;
import 'package:tacx_desktop/src/ui/bluetooth_tips.dart';
import 'package:tacx_desktop/src/ui/mode_copy.dart';
import 'package:tacx_desktop/src/ui/app_tokens.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/route_map.dart';
import 'package:tacx_desktop/src/ui/status_bar.dart';
import 'package:tacx_desktop/src/ui/window_chrome.dart';


class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});

  /// Full dashboard builds — tests assert live metric ticks don't bump it.
  @visibleForTesting
  static int debugBuilds = 0;

  /// Metric-card rebuilds driven by the live metrics notifier.
  @visibleForTesting
  static int debugMetricsBuilds = 0;

  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  Timer? _poll;

  /// Shared by the compact-mode Scrollbar and scroll view so switching
  /// between roomy and compact layouts never leaves the Scrollbar without a
  /// ScrollPosition (opening Simulation / resizing the window).
  final _scroll = ScrollController();
  List<DiscoveredDevice> _devices = [];
  DiscoveredDevice? _selected;
  /// Live trainer metrics / ride totals change ~4x per second while riding.
  /// They live in notifiers so only the metric cards, ride strip and Focus
  /// view rebuild per tick — not the header, connection bar or control
  /// panels (P0-P2 rebuild isolation).
  final ValueNotifier<TrainerMetrics> _metricsN = ValueNotifier(
    const TrainerMetrics(powerW: 0, cadenceRpm: 0, speedKmh: 0),
  );
  TrainerMetrics get _metrics => _metricsN.value;
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
  final ValueNotifier<RideStats> _rideN = ValueNotifier(
    const RideStats(
      elapsedS: 0,
      movingS: 0,
      avgPowerW: 0,
      maxPowerW: 0,
      avgCadenceRpm: 0,
      energyKj: 0,
      distanceKm: 0,
      avgHeartRateBpm: 0,
      maxHeartRateBpm: 0,
      recording: false,
    ),
  );
  RideStats get _ride => _rideN.value;

  /// Trainer link health for the status bar (polled with the metrics).
  final ValueNotifier<LinkHealth> _linkN = ValueNotifier(
    const LinkHealth(packetsPerS: 0, level: LinkLevel.noData),
  );
  /// 1 Hz rolling history (last 10 min) for the live power/cadence/HR graph.
  final TrendBuffer _trend = TrendBuffer();
  List<WorkoutInfo> _workouts = const [];
  WorkoutStatus _workout = const WorkoutStatus(
    running: false,
    workoutId: '',
    workoutName: '',
    stepIndex: 0,
    stepCount: 0,
    remainingS: 0,
    statusText: 'Idle',
    done: false,
  );
  RouteStatus _route = const RouteStatus(
    running: false,
    routeName: '',
    distanceM: 0,
    progressM: 0,
    gradePct: 0,
    complete: false,
    statusText: '',
  );
  GpxProfileInfo? _gpx;
  /// Planned steps of the running / just-finished workout (ride graph).
  WorkoutPlan? _plan;
  /// Actual power on the workout time axis (1 Hz).
  final WorkoutTrace _wTrace = WorkoutTrace();
  /// Live workout status (time left, ramp target). Updated every poll
  /// without rebuilding the dashboard; only the workout widgets listen.
  late final ValueNotifier<WorkoutStatus> _workoutN = ValueNotifier(_workout);
  /// Rider FTP for zone colours (persisted).
  int _ftp = 200;

  /// Ghost race on a repeated GPX route (best attempt, live attempt).
  GhostStore? _ghostStore;
  /// Route being ridden (markers, best, save target). The loaded [_gpx] may
  /// differ while a route runs: it is shown as queued (QA G3).
  GpxProfileInfo? _ridingGpx;
  String? _routeKey;
  String? _legacyKey;
  GhostTrack? _best;
  final AttemptRecorder _attempt = AttemptRecorder();
  /// Monotonic clocks (no NTP / suspend jumps, G8).
  final Stopwatch _routeClock = Stopwatch();
  final Stopwatch _mono = Stopwatch()..start();
  bool _attemptLive = false;
  double? _notRunningSinceS;
  double? _ghostM;
  double? _ghostDeltaS;
  /// Route map: geometry built once per shown GPX; rider / ghost positions
  /// drive only the dot layer (no dashboard rebuild).
  RouteGeo? _geo;
  final ValueNotifier<double?> _mapRiderM = ValueNotifier(null);
  final ValueNotifier<double?> _mapGhostM = ValueNotifier(null);

  /// Chart / map hover preview (metres along the route); null = none.
  final ValueNotifier<double?> _hoverM = ValueNotifier(null);
  bool _ergFromGrade = false;

  HrStrapStatus _strap = const HrStrapStatus(
    state: HrStrapState.disconnected,
    deviceId: '',
    deviceName: '',
    detail: '',
  );
  List<DiscoveredDevice> _straps = [];
  String? _strapPick;
  bool _strapSearching = false;
  String? _strapNote;

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
  /// Focus / game-mode ride view (P0-F1). Persisted via [RidePrefs].
  bool _focusMode = false;
  /// Zone wash / cadence pulse — off by default (P0-V3).
  FocusEffects _focusEffects = FocusEffects.off;
  Timer? _prefsSave;
  /// Non-null once the rider (or a test) toggles Demo before prefs finish
  /// loading — keeps async prefs from stomping the explicit choice.
  bool? _demoUserChoice;

  @override
  void initState() {
    super.initState();
    // Demo defaults OFF (Rust + prefs). Prefs may re-enable after load.
    api.setDemoMode(enabled: false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reloadWorkouts());
    _refresh();
    _checkBluetooth();
    _loadPrefs();
    _poll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_prefsSave?.isActive ?? false) {
      _prefsSave!.cancel();
      _currentPrefs().save();
    }
    _scroll.dispose();
    _metricsN.dispose();
    _rideN.dispose();
    _linkN.dispose();
    _trend.dispose();
    _wTrace.dispose();
    _workoutN.dispose();
    _mapRiderM.dispose();
    _mapGhostM.dispose();
    _hoverM.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final wasReconnecting = _snap.state == ConnectionState.reconnecting;
    final metrics = api.getMetrics();
    final snap = api.getConnectionSnapshot();
    final resRange = api.getResistanceRange();
    final interval = api.getIntervalStatus();
    // A default status (empty text) means the read was not possible: keep
    // the last one instead of flashing "no workout" (and dropping the plan).
    final rawWorkout = api.getWorkoutStatus();
    final workout = rawWorkout.statusText.isEmpty ? _workoutN.value : rawWorkout;
    final route = api.getRouteStatus();
    final ride = api.getRideStats();
    final strap = api.getHeartRateStrapStatus();
    final ghostChanged = _trackGhost(route);
    _mapRiderM.value =
        route.running || route.complete ? route.progressM : null;
    _mapGhostM.value = route.running ? _ghostM : null;
    final plan = _planFor(workout);
    // Only real samples go on the trace: no default / disconnected zeros.
    if (plan != null &&
        workout.running &&
        snap.state == ConnectionState.connected &&
        (metrics.powerW > 0 || metrics.cadenceRpm > 0)) {
      _wTrace.offer(
        plan.id,
        plan.elapsedFrom(
          stepIndex: workout.stepIndex,
          remainingS: workout.remainingS,
        ),
        metrics.powerW,
      );
    }
    final simExpand = snap.mode == ControlMode.simulation && !_simExpanded;
    // P0-P2: the whole dashboard (header, connection bar, controls) only
    // rebuilds when connection/control state changes. Live power, cadence,
    // speed, HR and ride totals go through notifiers, so a steady ride
    // rebuilds just the metric cards / ride strip / Focus view each tick.
    // The ERG panel shows the trainer's live target, so that one field
    // still triggers a full rebuild.
    final changed = simExpand ||
        snap != _snap ||
        resRange != _resRange ||
        interval != _interval ||
        _workoutShape(workout) != _workoutShape(_workout) ||
        route != _route ||
        strap != _strap ||
        !identical(plan, _plan) ||
        ghostChanged ||
        metrics.targetPowerW != _metrics.targetPowerW;
    _metricsN.value = metrics;
    _rideN.value = ride;
    _linkN.value = api.getLinkHealth();
    _workoutN.value = workout;
    final err = workout.error;
    if (err != null && err != _workout.error) {
      _toast('Workout stopped: $err', Icons.error_outline);
    }
    // Only graph while a trainer (or Demo) is actually streaming.
    if (snap.state == ConnectionState.connected) {
      _trend.offer(metrics, DateTime.now());
    }
    if (changed) {
      setState(() {
        _snap = snap;
        _resRange = resRange;
        _interval = interval;
        _workout = workout;
        _route = route;
        _strap = strap;
        _plan = plan;
        if (simExpand) _simExpanded = true;
      });
    }
    if (wasReconnecting && _snap.state == ConnectionState.connected) {
      _toast('Trainer reconnected — previous target restored', Icons.link);
    }
  }

  GhostStore? get _ghosts {
    if (_ghostStore != null) return _ghostStore;
    final override = GhostStore.debugDirOverride;
    if (override != null) return _ghostStore = GhostStore(override);
    try {
      return _ghostStore = GhostStore.besideWorkouts(api.workoutsDir());
    } catch (_) {
      return null;
    }
  }

  /// The route whose best / markers are shown: the one being ridden, else
  /// the loaded GPX.
  GpxProfileInfo? get _shownGpx => _ridingGpx ?? _gpx;

  void _setHover(double? m) => _hoverM.value = m;

  /// Route geometry for [_shownGpx], rebuilt only when that route changes.
  RouteGeo? get _routeGeo {
    final p = _shownGpx;
    if (p == null || p.samples.length < 2) return _geo = null;
    final g = _geo;
    if (g != null && identical(g.samples, p.samples)) return g;
    return _geo = RouteGeo(p.samples);
  }

  /// Loads the stored best (v2 key, legacy fallback) for [_shownGpx].
  void _loadBestForGpx() {
    final p = _shownGpx;
    if (p == null || p.samples.length < 2) {
      _routeKey = _legacyKey = null;
      _best = null;
      return;
    }
    _routeKey = p.routeKey;
    _legacyKey = legacyRouteKey(p);
    _best = _ghosts
        ?.loadForRoute(
          key: p.routeKey,
          legacyKey: _legacyKey!,
          routeName: p.name,
          distanceM: p.distanceM,
        )
        ?.track;
  }

  double get _routeT => _routeClock.elapsedMicroseconds / 1e6;

  /// Ends the live attempt (finish, stop, or confirmed dropout).
  void _endAttempt() {
    _attemptLive = false;
    _routeClock.stop();
    _notRunningSinceS = null;
    _ghostM = null;
    _ghostDeltaS = null;
    _ridingGpx = null;
    _loadBestForGpx(); // the queued / loaded GPX becomes current again
  }

  /// Ghost race bookkeeping for one poll. Returns true when the visible
  /// ghost state (marker / delta) changed.
  bool _trackGhost(RouteStatus route) {
    final oldM = _ghostM, oldD = _ghostDeltaS, oldKey = _routeKey;
    final nowS = _mono.elapsedMicroseconds / 1e6;
    if (route.running) {
      _notRunningSinceS = null;
      if (!_attemptLive) {
        _attemptLive = true;
        _attempt.reset();
        _routeClock
          ..reset()
          ..start();
        _ridingGpx ??= _gpx;
        _loadBestForGpx();
      }
      final t = _routeT;
      _attempt.offer(t, route.progressM);
      final best = _best;
      if (best != null && !best.isEmpty) {
        _ghostM = best.distanceAt(t);
        // Monotonic distance from the recorder: a glitchy progress read
        // can't show a fake "+" (G7).
        _ghostDeltaS = ghostDeltaS(best, _attempt.lastD, t);
      } else {
        _ghostM = null;
        _ghostDeltaS = null;
      }
    } else if (_attemptLive) {
      if (route.complete) {
        final t = _routeT;
        _attempt.finish(t, route.progressM);
        final key = _routeKey;
        final store = _ghosts;
        final riding = _ridingGpx;
        if (key != null && store != null && riding != null) {
          final prev = _best;
          if (store.saveIfBest(
            key,
            riding.name,
            riding.distanceM,
            _attempt.toTrack(),
            legacyKey: _legacyKey,
            isDemo: _snap.isDemo, // Demo speed is synthetic (G2)
          )) {
            final gain = prev == null ? '' : ' (${fmtDelta(t - prev.totalS)})';
            _toast(
              'New best on ${riding.name}: ${fmtClock(t)}$gain',
              Icons.emoji_events_outlined,
            );
          } else if (_snap.isDemo) {
            _toast('Demo ride — not saved as your best', Icons.info_outline);
          }
        }
        _endAttempt();
      } else {
        // Only a sustained "not running" ends the attempt: one odd poll
        // must never restart it mid-route (G1).
        _notRunningSinceS ??= nowS;
        if (nowS - _notRunningSinceS! >= 1.0) _endAttempt();
      }
    }
    return oldM != _ghostM ||
        oldD?.round() != _ghostDeltaS?.round() ||
        oldKey != _routeKey;
  }

  /// "Reset best" for the shown route.
  void _resetBest() {
    final key = _routeKey;
    if (key == null) return;
    final store = _ghosts;
    var removed = store?.resetBest(key) ?? false;
    final legacy = _legacyKey;
    if (legacy != null) removed = (store?.resetBest(legacy) ?? false) || removed;
    setState(() => _best = null);
    _toast(removed ? 'Best cleared' : 'No best to clear', Icons.restart_alt);
  }

  /// Export the best for the shown route as a `.tdshare` file next to the
  /// ghosts (no file picker dependency yet).
  void _exportGhost() {
    final key = _routeKey, store = _ghosts, p = _shownGpx;
    if (key == null || store == null || p == null) return;
    final safe = p.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final dest = File(
      '${store.dir.parent.path}${Platform.pathSeparator}shared'
      '${Platform.pathSeparator}$safe-${key.replaceAll('v2-', '')}.tdshare',
    );
    final out = store.exportShare(key, dest);
    _toast(
      out == null ? 'No (non-demo) best to export' : 'Ghost exported: ${out.path}',
      out == null ? Icons.info_outline : Icons.ios_share,
    );
  }

  /// Import a friend's `.tdshare` for the shown route from a path.
  Future<void> _importGhost() async {
    final key = _routeKey, store = _ghosts, p = _shownGpx;
    if (key == null || store == null || p == null) return;
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import ghost (.tdshare)'),
        content: TextField(
          key: const ValueKey('ghost-import-path'),
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '/path/to/friend.tdshare'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (path == null || path.trim().isEmpty) return;
    try {
      final g = store.importShare(File(path.trim()), key: key, routeDistanceM: p.distanceM);
      final who = g.riderName.isEmpty ? 'Friend' : g.riderName;
      _toast('$who\'s ghost imported (${fmtClock(g.totalS)})', Icons.group_outlined);
    } on FormatException catch (e) {
      _toast('Import failed: ${e.message}', Icons.error_outline);
    } catch (e) {
      _toast('Import failed: $e', Icons.error_outline);
    }
  }

  /// Planned steps for the workout in [st] (cached per workout id). Null
  /// when no workout is running or just finished.
  WorkoutPlan? _planFor(WorkoutStatus st) {
    if (!(st.running || st.done) || st.workoutId.isEmpty) return null;
    final cur = _plan;
    if (cur != null && cur.id == st.workoutId) return cur;
    try {
      return WorkoutPlan.tryParse(api.loadWorkoutJson(id: st.workoutId));
    } catch (_) {
      return null;
    }
  }

  /// The parts of a workout status that change the dashboard layout.
  /// Time left / ramp target change 4×/s and only drive [_workoutN].
  static Object _workoutShape(WorkoutStatus w) => (
    w.running,
    w.done,
    w.workoutId,
    w.stepIndex,
    w.stepCount,
    w.error,
  );

  static WorkoutProgress _progressOf(WorkoutStatus w) => WorkoutProgress(
    stepIndex: w.stepIndex,
    remainingS: w.remainingS,
    running: w.running,
    done: w.done,
  );

  Widget _workoutView({required bool large}) {
    final plan = _plan!;
    return ValueListenableBuilder<WorkoutStatus>(
      valueListenable: _workoutN,
      builder: (context, w, _) => WorkoutRideView(
        plan: plan,
        progress: _progressOf(w),
        trace: _wTrace,
        ftp: _ftp,
        large: large,
        onEditFtp: _editFtp,
      ),
    );
  }

  Future<void> _editFtp() async {
    final ctrl = TextEditingController(text: '$_ftp');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RideColors.surface,
        title: const Text('FTP (W)'),
        content: TextField(
          key: const ValueKey('ftp-field'),
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            helperText: 'Colours the workout graph zones (50–600 W)',
          ),
          onSubmitted: (t) => Navigator.pop(ctx, int.tryParse(t)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (v == null || !mounted) return;
    _setPref(() => _ftp = v.clamp(50, 600));
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

  /// Writes the ride to `~/Documents/Tacx Desktop/tacx-ride-<UTC>.tcx`.
  Future<void> _exportRide() async {
    try {
      final path = await api.exportRideTcx();
      if (mounted) _toast('Ride saved: $path', Icons.save_alt);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

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

  /// Heart-rate strap search runs beside the trainer link (never blocks
  /// trainer controls via [_busy]).
  Future<void> _searchStraps() async {
    setState(() {
      _strapSearching = true;
      _strapNote = null;
    });
    try {
      final list = await api.scanHeartRateStraps(timeoutMs: 6000);
      if (!mounted) return;
      setState(() {
        _straps = list;
        if (!list.any((d) => d.id == _strapPick)) {
          _strapPick = list.isEmpty ? null : list.first.id;
        }
        _strapNote = list.isEmpty
            ? 'No heart-rate strap found — wear it (it sleeps when dry), then search again'
            : null;
      });
    } catch (e) {
      if (mounted) setState(() => _strapNote = e.toString());
    } finally {
      if (mounted) setState(() => _strapSearching = false);
    }
  }

  Future<void> _connectStrap() async {
    final id = _strapPick ?? (_straps.isEmpty ? null : _straps.first.id);
    if (id == null) return;
    try {
      await api.connectHeartRateStrap(deviceId: id);
      _refresh();
      if (mounted) _toast('Heart-rate strap connected', Icons.favorite);
    } catch (e) {
      _refresh();
    }
  }

  Future<void> _disconnectStrap() async {
    await api.disconnectHeartRateStrap();
    _refresh();
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


  /// Restore last session's ride settings (Focus, effects, ERG target/step,
  /// rider weight, resistance auto-apply). Only touches local UI state —
  /// nothing is written to the trainer until the rider presses Apply.
  void _reloadWorkouts() {
    List<WorkoutInfo> list = const [];
    try {
      list = api.listWorkouts();
    } catch (_) {}
    if (!mounted) {
      _workouts = list;
      return;
    }
    setState(() => _workouts = list);
  }

  Future<void> _loadPrefs() async {
    final p = await RidePrefs.load();
    if (p == null || !mounted) return;
    final demo = _demoUserChoice ?? p.demoMode;
    api.setDemoMode(enabled: demo);
    setState(() {
      _focusMode = p.focusMode;
      _focusEffects =
          p.focusEffectsSubtle ? FocusEffects.subtle : FocusEffects.off;
      _targetWatts = p.targetWatts;
      _ergStep = p.ergStep;
      _userWeightKg = p.userWeightKg;
      _resAutoApply = p.resAutoApply;
      _ftp = p.ftpWatts;
      if (!demo) {
        _devices = [];
        _selected = null;
        _didScan = false;
      }
    });
    _refresh();
    _checkBluetooth();
  }

  RidePrefs _currentPrefs() => RidePrefs(
    focusMode: _focusMode,
    focusEffectsSubtle: _focusEffects == FocusEffects.subtle,
    targetWatts: _targetWatts,
    ergStep: _ergStep,
    userWeightKg: _userWeightKg,
    resAutoApply: _resAutoApply,
    demoMode: _snap.isDemo,
    welcomeSeen: true,
    ftpWatts: _ftp,
  );

  /// Debounced so slider drags / rapid −/+ taps write once.
  void _savePrefsSoon() {
    _prefsSave?.cancel();
    _prefsSave = Timer(const Duration(milliseconds: 600), () {
      _currentPrefs().save();
    });
  }

  /// setState + persist ride settings.
  void _setPref(VoidCallback fn) {
    setState(fn);
    _savePrefsSoon();
  }

  /// Demo can't be toggled while a connect / disconnect is in flight (the
  /// BLE handshake runs unlocked in Rust; see connect_gen there too).
  bool get _demoLocked =>
      _busy || _snap.state == ConnectionState.connecting;

  /// Toggle Demo mode: clear any stub/live scan list, persist preference.
  void _setDemoMode(bool enabled) {
    // QA B3: never flip Demo while a connect / disconnect is in flight.
    if (_demoLocked) return;
    _demoUserChoice = enabled;
    api.setDemoMode(enabled: enabled);
    setState(() {
      _devices = [];
      _selected = null;
      _error = null;
      _didScan = false;
    });
    _refresh();
    _checkBluetooth();
    _savePrefsSoon();
  }

  bool get _canRide =>
      _snap.state == ConnectionState.connected || _snap.isDemo;

  /// Focus chrome only when Focus is on and a trainer (or Demo) is available.
  bool get _inFocus => _focusMode && _canRide;

  void _toggleFocusMode() {
    if (!_focusMode && !_canRide) {
      _toast(
        'Connect a trainer or enable Demo',
        Icons.link_off,
      );
      return;
    }
    _setPref(() => _focusMode = !_focusMode);
  }

  Future<void> _toggleFullScreen() async {
    await WindowChrome.toggleFullScreen();
    if (mounted) setState(() {});
  }

  Future<void> _exitFullScreenOnly() async {
    if (await WindowChrome.isFullScreen()) {
      await WindowChrome.setFullScreen(false);
      if (mounted) setState(() {});
    }
  }

  Future<void> _enterImmersive() async {
    if (!_canRide) {
      _toast('Connect a trainer or enable Demo', Icons.link_off);
      return;
    }
    _setPref(() => _focusMode = true);
    await WindowChrome.setFullScreen(true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    RideDashboard.debugBuilds++;
    final connected = _snap.state == ConnectionState.connected;
    final theme = Theme.of(context);
    final simSupported = _snap.supportsSimulation || _snap.isDemo;
    final activeMode = _snap.mode;

    final intervalRunning =
        _interval.running || _workout.running || _route.running;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyG): _toggleFocusMode,
        const SingleActivator(LogicalKeyboardKey.f11): () {
          _toggleFullScreen();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _exitFullScreenOnly();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (!_inFocus)
                  _Header(
                    snap: _snap,
                    demo: _snap.isDemo,
                    focusMode: _focusMode,
                    focusEffects: _focusEffects,
                    canFocus: _canRide || _focusMode,
                    onFocusToggle: _toggleFocusMode,
                    onImmersive: _canRide || _focusMode
                        ? _enterImmersive
                        : () => _toast(
                              'Connect a trainer or enable Demo',
                              Icons.link_off,
                            ),
                    onFullScreen: _toggleFullScreen,
                    onEffectsChanged: (e) =>
                        _setPref(() => _focusEffects = e),
                    onDemoChanged: _demoLocked ? null : _setDemoMode,
                    onShowModes: () => showModesDialog(context),
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
                    onPressed: () => _setDemoMode(true),
                    child: const Text(
                      'Use demo',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            if (_route.complete && !_focusMode)
              _StatusStrip(
                key: const ValueKey('route-complete-strip'),
                icon: Icons.flag,
                color: RideColors.bannerInfo,
                message: _route.statusText.isEmpty
                    ? 'Route complete — grade set to 0%'
                    : _route.statusText,
                actions: const [],
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
              child: _inFocus
                  ? ListenableBuilder(
                    listenable: Listenable.merge([_metricsN, _rideN]),
                    builder: (context, _) => FocusRideView(
                      key: const ValueKey('focus-ride-view'),
                      metrics: _metrics,
                      snap: _snap,
                      ride: _ride,
                      targetWatts: _targetWatts,
                      ergStep: _ergStep,
                      connected: connected,
                      busy: _busy,
                      effects: _focusEffects,
                      intervalRunning:
                          intervalRunning || _workout.running || _route.running,
                      workoutView: _plan == null
                          ? null
                          : _workoutView(large: true),
                      routeChip: _ghostDeltaS == null
                          ? null
                          : GhostDeltaChip(deltaS: _ghostDeltaS!, large: true),
                      onExitFocus: _toggleFocusMode,
                      onDisconnect: () => _run(
                        () => api.disconnectTrainer(),
                        label: 'Disconnecting',
                      ),
                      onStopInterval: () {
                        api.stopInterval();
                        api.stopWorkout();
                        api.stopGpxRoute();
                        _refresh();
                      },
                      onNudge: (d) => _setPref(
                        () => _targetWatts =
                            (_targetWatts + d * _ergStep).clamp(0, 2000),
                      ),
                      onApplyErg: () => _run(
                        () => api.setTargetPower(watts: _targetWatts),
                        success:
                            'ERG $_targetWatts W sent — allow 3–5 s to settle (Kickr)',
                        successIcon: Icons.bolt,
                      ),
                      onStepChanged: (s) => _setPref(() => _ergStep = s),
                    ),
                  )
                  : Padding(
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
                    // Ride summary strip + heart-rate strap bar sit between
                    // metrics and controls (48 px + 8 px gap each).
                    // Live graph adds 88 px + 8 px gap.
                    // Workout ride view adds 200 px + 8 px gap while active.
                    final neededWithRide =
                        needed + 56 + 56 + 96 + (_plan != null ? 208 : 0);
                    final compact = box.maxHeight < neededWithRide;
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
                            onUseDemo: () => _setDemoMode(true),
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
                        RepaintBoundary(
                          child: ValueListenableBuilder<TrainerMetrics>(
                            valueListenable: _metricsN,
                            builder: (context, m, _) {
                              RideDashboard.debugMetricsBuilds++;
                              return _MetricsRow(metrics: m, snap: _snap);
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        RepaintBoundary(
                          child: ValueListenableBuilder<RideStats>(
                            valueListenable: _rideN,
                            builder: (context, r, _) => RideSummaryStrip(
                              key: const ValueKey('ride-summary'),
                              stats: r,
                              // Disabled mid route / workout (G7).
                              onReset: _route.running || _workout.running
                                  ? null
                                  : () {
                                      api.resetRideStats();
                                      _trend.clear();
                                      _refresh();
                                    },
                              onExport: _exportRide,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_plan != null) ...[
                          SizedBox(
                            height: 200,
                            child: _workoutView(large: false),
                          ),
                          const SizedBox(height: 8),
                        ],
                        RepaintBoundary(
                          child: LiveTrendChart(
                            buffer: _trend,
                            targetWatts: (_workoutN.value.targetWatts?.toDouble() ??
                                _metrics.targetPowerW),
                          ),
                        ),
                        const SizedBox(height: 8),
                        HeartRateStrapBar(
                          status: _strap,
                          straps: _straps,
                          selectedId: _strapPick,
                          searching: _strapSearching,
                          note: _strapNote,
                          onSearch: _searchStraps,
                          onSelect: (id) => setState(() => _strapPick = id),
                          onConnect: _connectStrap,
                          onDisconnect: _disconnectStrap,
                        ),
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
                                    onStep: (s) => _setPref(() => _ergStep = s),
                                    onNudge: (d) => _setPref(
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
                                          'ERG ${_targetWatts.round()} W sent — allow 3–5 s to settle (Kickr)',
                                      successIcon: Icons.bolt,
                                    ),
                                    onSetExact: (w) {
                                      _setPref(() => _targetWatts = w);
                                      _run(
                                        () => api.setTargetPower(watts: w),
                                        success:
                                            'ERG ${w.round()} W sent — allow 3–5 s to settle (Kickr)',
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
                                    // Kickr Bike / missing 0x2AD6 → maxPct <= 0
                                    supported: _resRange.maxPct > 0,
                                    enabled: connected &&
                                        !_busy &&
                                        _resRange.maxPct > 0,
                                    onChanged: (v) =>
                                        setState(() => _resistancePct = v),
                                    onApply: _applyResistance,
                                    autoApply: _resAutoApply,
                                    onAutoApplyChanged: (v) =>
                                        _setPref(() => _resAutoApply = v),
                                    onChangeEnd: (v) {
                                      _resistancePct = v;
                                      if (_resAutoApply && _resRange.maxPct > 0) {
                                        _applyResistance();
                                      }
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ValueListenableBuilder<WorkoutStatus>(
 valueListenable: _workoutN,
 builder: (context, liveWorkout, _) => WorkoutPanel(
                                  workouts: _workouts.isEmpty
                                      ? const []
                                      : _workouts,
                                  workoutStatus: liveWorkout,
                                  routeStatus: _route,
                                  gpxProfile: _shownGpx,
                                  queuedGpxName: _ridingGpx != null &&
                                          _gpx != null &&
                                          !identical(_gpx, _ridingGpx)
                                      ? _gpx!.name
                                      : null,
                                  onResetBest: _best == null ? null : _resetBest,
                                  onExportGhost: _best == null ? null : _exportGhost,
                                  onImportGhost: _routeKey == null ? null : _importGhost,
                                  routeMap: _routeGeo == null
                                      ? null
                                      : RouteMap(
                                          geo: _routeGeo!,
                                          progressM: _mapRiderM,
                                          ghostM: _mapGhostM,
                                          hoverM: _hoverM,
                                          onHover: _setHover,
                                        ),
                                  elevChart: _shownGpx == null
                                      ? null
                                      : ElevProfileChart(
                                          profile: _shownGpx!,
                                          geo: _routeGeo,
                                          riderM: _mapRiderM,
                                          ghostM: _mapGhostM,
                                          hoverM: _hoverM,
                                          onHover: _setHover,
                                        ),
                                  ergFromGrade: _ergFromGrade,
                                  enabled: connected && !_busy,
                                  supportsSimulation: simSupported,
                                  onRefreshList: _reloadWorkouts,
                                  onStartWorkout: (id) => _run(
                                    () async {
                                      api.setWorkoutRiderMassKg(
                                        kg: _userWeightKg,
                                      );
                                      await api.startWorkout(id: id);
                                    },
                                    success: 'Workout started',
                                    successIcon: Icons.fitness_center,
                                  ),
                                  onStopWorkout: () {
                                    api.stopWorkout();
                                    api.stopInterval();
                                    _refresh();
                                  },
                                  onImportGpxXml: (xml) {
                                    try {
                                      final p = api.parseGpxXml(xml: xml);
                                      setState(() {
                                        _gpx = p;
                                        // Mid-route paste is queued: the
                                        // ridden route keeps its markers and
                                        // ghost until finish / stop (G3).
                                        if (!_attemptLive) _loadBestForGpx();
                                      });
                                      _toast(
                                        _attemptLive
                                            ? 'GPX queued · ${p.name} (after this route)'
                                            : 'GPX loaded · ${(p.distanceM / 1000).toStringAsFixed(1)} km',
                                        Icons.terrain,
                                      );
                                    } catch (e) {
                                      _toast('$e', Icons.error_outline);
                                    }
                                  },
                                  onStartRoute: () => _run(
                                    () async {
                                      final p = _gpx;
                                      if (p == null) return;
                                      api.setErgFromGrade(
                                        enabled: _ergFromGrade,
                                      );
                                      api.setWorkoutRiderMassKg(
                                        kg: _userWeightKg,
                                      );
                                      await api.startGpxRoute(profile: p);
                                      _ridingGpx = p;
                                    },
                                    success: 'GPX route started',
                                    successIcon: Icons.terrain,
                                  ),
                                  onStopRoute: () {
                                    api.stopGpxRoute();
                                    if (_attemptLive) setState(_endAttempt);
                                    _refresh();
                                  },
                                  onErgFromGrade: (v) {
                                    setState(() => _ergFromGrade = v);
                                    api.setErgFromGrade(enabled: v);
                                  },
                                  ghostDeltaS: _ghostDeltaS,
                                  bestS: _best?.totalS,
                                  onSaveAsCopy: (info) {
                                    try {
                                      final json =
                                          api.loadWorkoutJson(id: info.id);
                                      api.saveWorkoutJson(json: json);
                                      _reloadWorkouts();
                                      _toast(
                                        'Saved copy under Documents/Tacx Desktop/workouts/',
                                        Icons.save_alt,
                                      );
                                    } catch (e) {
                                      _toast('$e', Icons.error_outline);
                                    }
                                  },
                                ),
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
                          onWeight: (v) => _setPref(() => _userWeightKg = v),
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
                          _bleFootnote(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: RideColors.textMuted,
                            fontSize: RideType.footnote,
                          ),
                        ),
                      ],
                    );
                    if (!compact) return body;
                    return Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        key: const ValueKey('dashboard-scroll'),
                        controller: _scroll,
                        padding: const EdgeInsets.only(right: 8),
                        child: body,
                      ),
                    );
                  },
                ),
              ),
            ),
            if (!_inFocus)
              RideStatusBar(
                snap: _snap,
                strap: _strap,
                ride: _rideN,
                link: _linkN,
                metrics: _metricsN,
              ),
          ],
        ),
      ),
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
    required this.focusMode,
    required this.focusEffects,
    required this.canFocus,
    required this.onFocusToggle,
    required this.onImmersive,
    required this.onFullScreen,
    required this.onEffectsChanged,
    required this.onShowModes,
  });

  final ConnectionSnapshot snap;
  final bool demo;
  /// Null while connecting / busy: the switch is disabled.
  final ValueChanged<bool>? onDemoChanged;
  final bool focusMode;
  final FocusEffects focusEffects;
  final bool canFocus;
  final VoidCallback onFocusToggle;
  final VoidCallback onImmersive;
  final VoidCallback onFullScreen;
  final ValueChanged<FocusEffects> onEffectsChanged;
  final VoidCallback onShowModes;

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
          const SizedBox(width: 8),
          Tooltip(
            message: canFocus
                ? 'Focus mode (G) — immersive power view'
                : 'Connect a trainer or enable Demo',
            child: TextButton.icon(
              key: const ValueKey('header-focus'),
              onPressed: canFocus ? onFocusToggle : null,
              icon: Icon(
                focusMode ? Icons.fullscreen_exit : Icons.sports_esports,
                color: canFocus ? Colors.white : Colors.white38,
                size: 20,
              ),
              label: Text(
                focusMode ? 'Exit Focus' : 'Focus',
                style: TextStyle(
                  color: canFocus ? Colors.white : Colors.white38,
                ),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('header-modes'),
            onPressed: onShowModes,
            child: const Text('Modes', style: TextStyle(color: Colors.white70)),
          ),
          Tooltip(
            message: 'Immersive = Focus + fullscreen (F11)',
            child: IconButton(
              key: const ValueKey('header-immersive'),
              onPressed: onImmersive,
              icon: const Icon(Icons.open_in_full, color: Colors.white70),
              tooltip: 'Immersive',
            ),
          ),
          Tooltip(
            message: 'Fullscreen (F11)',
            child: IconButton(
              key: const ValueKey('header-fullscreen'),
              onPressed: onFullScreen,
              icon: const Icon(Icons.fullscreen, color: Colors.white70),
            ),
          ),
          PopupMenuButton<FocusEffects>(
            tooltip: 'Focus visual effects (Subtle / Off)',
            onSelected: onEffectsChanged,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: FocusEffects.off,
                child: Text('Effects: Off'),
              ),
              const PopupMenuItem(
                value: FocusEffects.subtle,
                child: Text('Effects: Subtle'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                focusEffects == FocusEffects.subtle
                    ? Icons.auto_awesome
                    : Icons.auto_awesome_outlined,
                color: Colors.white70,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Text('Demo', style: TextStyle(color: Colors.white)),
          Switch(
            key: const ValueKey('demo-switch'),
            value: demo,
            onChanged: onDemoChanged,
          ),
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
                    decoration: InputDecoration(
                      labelText: snap.isDemo
                          ? 'Demo trainers (not real hardware)'
                          : 'Trainer',
                    ),
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
    'kickr_ftms' => 'Kickr',
    'tacx_fec' => 'FE-C',
    'demo' => 'Demo',
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
      'ftms' || 'kickr_ftms' => RideColors.accent,
      'tacx_fec' => RideColors.accentAlt,
      'demo' => RideColors.demo,
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

String _bleFootnote() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.linux:
      return 'Only one BLE client can control the trainer. Quit Zwift / Wahoo app / Tacx Training / '
          'MyWhoosh / TrainerRoad / Rouvy. Linux: forget the trainer in KDE/Plasma Bluetooth '
          '(do not OS-pair) — connect only in-app. Never run with sudo.';
    case TargetPlatform.windows:
      return 'Only one BLE client can control the trainer. Quit Zwift / Wahoo app / Tacx Training / '
          'MyWhoosh / TrainerRoad before connecting. Windows: leave Kickr/Tacx unpaired '
          'in OS Bluetooth settings.';
    case TargetPlatform.macOS:
      return 'Only one BLE client can control the trainer. Quit Zwift / Wahoo app first. '
          'Prefer Connect in-app; Forget This Device in macOS Bluetooth if control fails after OS pairing.';
    default:
      return 'Only one BLE client can control the trainer. Quit Zwift / Tacx Training / '
          'MyWhoosh / TrainerRoad before connecting.';
  }
}

String _emptyScanBullets() => BluetoothTips.emptyScanText();

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
                  Text(
                    _emptyScanBullets(),
                    style: const TextStyle(
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
        'Garuda/Arch: pacman -S bluez bluez-utils; systemctl enable --now bluetooth; '
            'usermod -aG bluetooth \$USER (log out/in); rfkill unblock bluetooth; '
            'bluetoothctl power on. Run as normal user — never sudo. Plasma session D-Bus required.',
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
          if (metrics.heartRateBpm != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                label: 'Heart rate',
                value: '${metrics.heartRateBpm}',
                unit: 'bpm',
                accent: RideColors.heart,
                valueSize: RideType.metric,
              ),
            ),
          ],
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

/// Ride totals under the live metrics: time, avg/max power, cadence, kJ, km,
/// and average heart rate when the trainer relays one.
class RideSummaryStrip extends StatelessWidget {
  const RideSummaryStrip({
    super.key,
    required this.stats,
    required this.onReset,
    this.onExport,
  });

  final RideStats stats;
  /// Null while a route / workout runs (button disabled).
  final VoidCallback? onReset;

  /// Saves the ride as a TCX file; disabled until something was recorded.
  final VoidCallback? onExport;

  static String clock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final items = <(String, String)>[
      ('Ride', clock(stats.elapsedS)),
      ('Avg', '${stats.avgPowerW.toStringAsFixed(0)} W'),
      ('Max', '${stats.maxPowerW.toStringAsFixed(0)} W'),
      ('Cad', '${stats.avgCadenceRpm.toStringAsFixed(0)} rpm'),
      ('Work', '${stats.energyKj.toStringAsFixed(0)} kJ'),
      ('Dist', '${stats.distanceKm.toStringAsFixed(2)} km'),
      if (stats.maxHeartRateBpm > 0)
        ('HR', '${stats.avgHeartRateBpm.toStringAsFixed(0)} bpm'),
    ];
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 12, right: 2),
      decoration: BoxDecoration(
        color: RideColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RideColors.border),
      ),
      child: Row(
        children: [
          Tooltip(
            message: stats.recording
                ? 'Recording while the trainer is connected'
                : 'Paused — connect a trainer to record',
            child: Icon(
              stats.recording
                  ? Icons.fiber_manual_record
                  : Icons.pause_circle_outline,
              size: 14,
              color: stats.recording ? RideColors.power : RideColors.textMuted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  for (final (label, value) in items) ...[
                    Text(
                      label.toUpperCase(),
                      style: const TextStyle(
                        color: RideColors.textSecondary,
                        fontSize: RideType.footnote,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      value,
                      key: ValueKey('ride-${label.toLowerCase()}'),
                      style: const TextStyle(
                        color: RideColors.textPrimary,
                        fontSize: RideType.body,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 18),
                  ],
                ],
              ),
            ),
          ),
          Tooltip(
            message:
                'Save this ride as a TCX file for Garmin Connect or Strava',
            child: TextButton.icon(
              key: const ValueKey('ride-export'),
              onPressed: stats.elapsedS > 0 ? onExport : null,
              style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
              icon: const Icon(Icons.save_alt, size: 16),
              label: const Text('Save TCX'),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('ride-reset'),
            onPressed: onReset,
            style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('Reset'),
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
                    fontFeatures: kTabularFeatures,
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
                fontFeatures: kTabularFeatures,
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
            const SizedBox(height: 8),
            const Text(
              'Kickr may take 3–5 s to settle after a target change — that lag is normal, not a failed Apply.',
              style: TextStyle(
                color: RideColors.textMuted,
                fontSize: RideType.footnote,
                height: 1.35,
              ),
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
    this.supported = true,
    required this.enabled,
    required this.onChanged,
    required this.onApply,
    required this.autoApply,
    required this.onAutoApplyChanged,
    required this.onChangeEnd,
  });

  final double percent;
  final ResistanceRange range;
  /// False when FTMS has no Resistance Range / Kickr Bike — show honest disabled UI.
  final bool supported;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final VoidCallback onApply;
  final bool autoApply;
  final ValueChanged<bool> onAutoApplyChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    if (!supported || range.maxPct <= 0) {
      return Opacity(
        opacity: 0.55,
        child: _Panel(
          title: 'Resistance',
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Not supported on this trainer (e.g. Kickr Bike). Use ERG or Simulation instead. '
              'Public FTMS only — no Wahoo proprietary resistance path.',
              style: TextStyle(
                color: RideColors.textSecondary,
                fontSize: RideType.label,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
    }
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
                fontFeatures: kTabularFeatures,
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
