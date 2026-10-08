// ════════════════════════════════════════════════════════════════════════════
// lib/providers/theme_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Controls the Guardian Watch application theme.
//
// Supported modes: system, light, dark.
// Persisted locally so the choice survives app restarts.
//

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  bool _initialized = false;
  bool _disposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get isInitialized => _initialized;

  /// Loads the saved theme preference.
  ///
  /// Idempotent — safe to call multiple times. Subsequent calls return
  /// immediately once the provider is initialized.
  Future<void> load() async {
    if (_initialized || _disposed) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;

      final savedIndex = prefs.getInt(AppConstants.keyThemeMode);

      if (savedIndex == null) {
        _themeMode = ThemeMode.system;
      } else {
        final safeIndex = savedIndex.clamp(0, ThemeMode.values.length - 1);
        _themeMode = ThemeMode.values[safeIndex];
      }
    } catch (e, stack) {
      debugPrint('Theme preference load failed: $e');
      debugPrintStack(stackTrace: stack);

      // Safest fallback — device default.
      _themeMode = ThemeMode.system;
    } finally {
      if (!_disposed) {
        _initialized = true;
        _safeNotify();
      }
    }
  }

  /// Changes and persists the current application theme.
  ///
  /// The UI updates immediately; the persistence write is best-effort.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_disposed) return;
    if (_themeMode == mode) return;

    _themeMode = mode;
    _safeNotify();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        AppConstants.keyThemeMode,
        ThemeMode.values.indexOf(mode),
      );
    } catch (e, stack) {
      debugPrint('Theme preference save failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  /// Resets the theme to follow the device setting.
  Future<void> resetToSystem() => setThemeMode(ThemeMode.system);

  // ─────────────────────────────────────────────────────────────────────────
  // Notify guard
  // ─────────────────────────────────────────────────────────────────────────

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispose
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
