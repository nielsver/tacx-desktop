import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Size;
import 'package:window_manager/window_manager.dart';

/// Thin facade over [window_manager] so widget tests (no native window) stay
/// quiet and Linux/Garuda can F11 fullscreen without crashing CI.
abstract final class WindowChrome {
  static bool available = false;

  /// Last windowed size before entering immersive fullscreen (restore on Esc).
  static Size? _restoreSize;

  static Future<void> init() async {
    if (kIsWeb) return;
    if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) return;
    try {
      await windowManager.ensureInitialized();
      available = true;
    } catch (e) {
      debugPrint('WindowChrome.init skipped: $e');
      available = false;
    }
  }

  static Future<bool> isFullScreen() async {
    if (!available) return false;
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  static Future<void> setFullScreen(bool full) async {
    if (!available) return;
    try {
      if (full) {
        final bounds = await windowManager.getBounds();
        _restoreSize = bounds.size;
        await windowManager.setFullScreen(true);
      } else {
        await windowManager.setFullScreen(false);
        final size = _restoreSize;
        if (size != null) {
          await windowManager.setSize(size);
          _restoreSize = null;
        }
      }
    } catch (e) {
      debugPrint('WindowChrome.setFullScreen($full) failed: $e');
    }
  }

  static Future<void> toggleFullScreen() async {
    final now = await isFullScreen();
    await setFullScreen(!now);
  }
}
