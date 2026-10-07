import 'package:shared_preferences/shared_preferences.dart';

/// Rider-facing settings that should survive an app restart: Focus mode,
/// Focus effects, ERG target + step, rider weight and resistance
/// auto-apply. Stored with `shared_preferences` (Linux: JSON file under
/// `~/.local/share/<app id>/`, Windows: AppData, macOS: NSUserDefaults).
///
/// Every load/save swallows platform errors so a missing plugin (tests,
/// sandboxed builds) just falls back to the in-memory defaults.
class RidePrefs {
  const RidePrefs({
    this.focusMode = false,
    this.focusEffectsSubtle = false,
    this.targetWatts = 150,
    this.ergStep = 10,
    this.userWeightKg = 75,
    this.resAutoApply = true,
  });

  final bool focusMode;
  final bool focusEffectsSubtle;
  final int targetWatts;
  final int ergStep;
  final double userWeightKg;
  final bool resAutoApply;

  static const _kFocus = 'ride.focusMode';
  static const _kEffects = 'ride.focusEffectsSubtle';
  static const _kTarget = 'ride.ergTargetW';
  static const _kStep = 'ride.ergStepW';
  static const _kWeight = 'ride.userWeightKg';
  static const _kResAuto = 'ride.resAutoApply';

  static const allowedSteps = [5, 10, 25];

  /// Clamp anything read from disk so a hand-edited or stale file can never
  /// push an absurd ERG target or weight to the trainer.
  RidePrefs sanitized() => RidePrefs(
    focusMode: focusMode,
    focusEffectsSubtle: focusEffectsSubtle,
    targetWatts: targetWatts.clamp(0, 2000),
    ergStep: allowedSteps.contains(ergStep) ? ergStep : 10,
    userWeightKg: userWeightKg.isFinite
        ? userWeightKg.clamp(40.0, 120.0).toDouble()
        : 75,
    resAutoApply: resAutoApply,
  );

  static Future<RidePrefs?> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      const d = RidePrefs();
      return RidePrefs(
        focusMode: p.getBool(_kFocus) ?? d.focusMode,
        focusEffectsSubtle: p.getBool(_kEffects) ?? d.focusEffectsSubtle,
        targetWatts: p.getInt(_kTarget) ?? d.targetWatts,
        ergStep: p.getInt(_kStep) ?? d.ergStep,
        userWeightKg: p.getDouble(_kWeight) ?? d.userWeightKg,
        resAutoApply: p.getBool(_kResAuto) ?? d.resAutoApply,
      ).sanitized();
    } catch (_) {
      return null;
    }
  }

  Future<bool> save() async {
    try {
      final s = sanitized();
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kFocus, s.focusMode);
      await p.setBool(_kEffects, s.focusEffectsSubtle);
      await p.setInt(_kTarget, s.targetWatts);
      await p.setInt(_kStep, s.ergStep);
      await p.setDouble(_kWeight, s.userWeightKg);
      await p.setBool(_kResAuto, s.resAutoApply);
      return true;
    } catch (_) {
      return false;
    }
  }
}
