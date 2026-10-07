import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/ride_prefs.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/ui/connect_page.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';
import 'package:tacx_desktop/src/ui/welcome_page.dart';

enum AppStep { loading, welcome, connect, ride }

/// First-run Welcome → Connect → Ride. Returning users skip Welcome.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.skipOnboarding = false});

  /// Widget tests open the ride dashboard directly.
  final bool skipOnboarding;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppStep _step = AppStep.loading;

  @override
  void initState() {
    super.initState();
    if (widget.skipOnboarding) {
      _step = AppStep.ride;
    } else {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    final p = await RidePrefs.load();
    if (!mounted) return;
    final seen = p?.welcomeSeen ?? false;
    // Ensure Demo matches prefs (default OFF) before Connect.
    api.setDemoMode(enabled: p?.demoMode ?? false);
    setState(() {
      _step = seen ? AppStep.connect : AppStep.welcome;
    });
  }

  Future<void> _markWelcomeSeen({required bool demo}) async {
    api.setDemoMode(enabled: demo);
    final cur = await RidePrefs.load() ?? const RidePrefs();
    await RidePrefs(
      focusMode: cur.focusMode,
      focusEffectsSubtle: cur.focusEffectsSubtle,
      targetWatts: cur.targetWatts,
      ergStep: cur.ergStep,
      userWeightKg: cur.userWeightKg,
      resAutoApply: cur.resAutoApply,
      demoMode: demo,
      welcomeSeen: true,
    ).save();
  }

  Future<void> _goConnect({required bool demo}) async {
    await _markWelcomeSeen(demo: demo);
    if (!mounted) return;
    setState(() => _step = AppStep.connect);
  }

  Future<void> _tryDemoFromConnect() async {
    api.setDemoMode(enabled: true);
    final cur = await RidePrefs.load() ?? const RidePrefs();
    await RidePrefs(
      focusMode: cur.focusMode,
      focusEffectsSubtle: cur.focusEffectsSubtle,
      targetWatts: cur.targetWatts,
      ergStep: cur.ergStep,
      userWeightKg: cur.userWeightKg,
      resAutoApply: cur.resAutoApply,
      demoMode: true,
      welcomeSeen: true,
    ).save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case AppStep.loading:
        return const Scaffold(
          key: ValueKey('app-loading'),
          body: Center(child: CircularProgressIndicator()),
        );
      case AppStep.welcome:
        return WelcomePage(
          onConnectTrainer: () => _goConnect(demo: false),
          onTryDemo: () => _goConnect(demo: true),
          onSkip: () => _goConnect(demo: false),
        );
      case AppStep.connect:
        return ConnectPage(
          onStartRide: () => setState(() => _step = AppStep.ride),
          onTryDemo: _tryDemoFromConnect,
        );
      case AppStep.ride:
        return const RideDashboard();
    }
  }
}
