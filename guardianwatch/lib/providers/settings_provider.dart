// ════════════════════════════════════════════════════════════════════════════
// lib/providers/settings_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// SettingsProvider — user-configurable alert thresholds and privacy options.
//
// Responsibilities:
//   Load persisted settings from SharedPreferences on startup
//   Persist every change immediately
//   Notify the background service when alert thresholds change
//   Coordinate with HealthExportService for opt-in state
//   Validate inputs before accepting them
//
// Design rules:
//   The stored values are the source of truth. In-memory state is a
//    cache that mirrors the prefs.
//   Threshold changes are validated to sane physiological ranges.
//   Every change notifies listeners AND any interested service.
//   All notifyListeners() paths are guarded by _disposed.
//   The provider does not own theme — that is ThemeProvider's job.
//
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import '../services/background_service.dart';
import '../services/health_export_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Value objects
// ════════════════════════════════════════════════════════════════════════════

/// Alert thresholds. Immutable snapshot.
@immutable
class AlertThresholds {
  final int heartRateHigh;
  final int spo2Low;
  final double temperatureHigh;
  final int batteryLow;
  final int batteryCritical;

  const AlertThresholds({
    required this.heartRateHigh,
    required this.spo2Low,
    required this.temperatureHigh,
    required this.batteryLow,
    required this.batteryCritical,
  });

  static const AlertThresholds defaults = AlertThresholds(
    heartRateHigh: AppConstants.defaultHrHigh,
    spo2Low: AppConstants.defaultSpo2Low,
    temperatureHigh: AppConstants.defaultTempHigh,
    batteryLow: AppConstants.defaultBatteryLow,
    batteryCritical: AppConstants.defaultBatteryCritical,
  );

  AlertThresholds copyWith({
    int? heartRateHigh,
    int? spo2Low,
    double? temperatureHigh,
    int? batteryLow,
    int? batteryCritical,
  }) {
    return AlertThresholds(
      heartRateHigh: heartRateHigh ?? this.heartRateHigh,
      spo2Low: spo2Low ?? this.spo2Low,
      temperatureHigh: temperatureHigh ?? this.temperatureHigh,
      batteryLow: batteryLow ?? this.batteryLow,
      batteryCritical: batteryCritical ?? this.batteryCritical,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertThresholds &&
          other.heartRateHigh == heartRateHigh &&
          other.spo2Low == spo2Low &&
          other.temperatureHigh == temperatureHigh &&
          other.batteryLow == batteryLow &&
          other.batteryCritical == batteryCritical;

  @override
  int get hashCode => Object.hash(
    heartRateHigh,
    spo2Low,
    temperatureHigh,
    batteryLow,
    batteryCritical,
  );
}

/// Result of a settings mutation that can fail.
enum SettingsChangeResult { success, invalid, unavailable, error }

// ════════════════════════════════════════════════════════════════════════════
// Provider
// ════════════════════════════════════════════════════════════════════════════

class SettingsProvider extends ChangeNotifier {
  SettingsProvider();

  // ── State ─────────────────────────────────────────────────────────────────

  AlertThresholds _thresholds = AlertThresholds.defaults;

  bool _healthExportEnabled = false;
  bool _cloudSyncEnabled = true;
  int _retentionDays = 90;

  bool _initialized = false;
  bool _disposed = false;

  final Completer<void> _readyCompleter = Completer<void>();

  // ── Public state ──────────────────────────────────────────────────────────

  AlertThresholds get thresholds => _thresholds;

  int get heartRateHigh => _thresholds.heartRateHigh;
  int get spo2Low => _thresholds.spo2Low;
  double get temperatureHigh => _thresholds.temperatureHigh;
  int get batteryLow => _thresholds.batteryLow;
  int get batteryCritical => _thresholds.batteryCritical;

  bool get healthExportEnabled => _healthExportEnabled;
  bool get cloudSyncEnabled => _cloudSyncEnabled;
  int get retentionDays => _retentionDays;

  bool get isInitialized => _initialized;
  bool get isReady => _initialized;

  /// Awaits the first load from SharedPreferences.
  Future<void> waitUntilReady() => _readyCompleter.future;

  // ══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ══════════════════════════════════════════════════════════════════════════

  /// Loads persisted settings.
  ///
  /// Idempotent. Safe to call from app bootstrap.
  Future<void> load() async {
    if (_initialized || _disposed) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;

      _thresholds = AlertThresholds(
        heartRateHigh:
            prefs.getInt(AppConstants.keyAlertHrHigh) ??
            AlertThresholds.defaults.heartRateHigh,
        spo2Low:
            prefs.getInt(AppConstants.keyAlertSpo2Low) ??
            AlertThresholds.defaults.spo2Low,
        temperatureHigh:
            prefs.getDouble(AppConstants.keyAlertTempHigh) ??
            AlertThresholds.defaults.temperatureHigh,
        batteryLow:
            prefs.getInt(AppConstants.keyAlertBatteryLow) ??
            AlertThresholds.defaults.batteryLow,
        batteryCritical:
            prefs.getInt(AppConstants.keyAlertBatteryCritical) ??
            AlertThresholds.defaults.batteryCritical,
      );

      _healthExportEnabled =
          prefs.getBool(AppConstants.keyHealthOptIn) ?? false;

      _cloudSyncEnabled =
          prefs.getBool(AppConstants.keyCloudSyncEnabled) ?? true;

      _retentionDays = prefs.getInt(AppConstants.keyRetentionDays) ?? 90;

      // Sanity-clamp in case stored values are outside the valid range.
      _thresholds = _sanitize(_thresholds);
    } catch (e, stack) {
      debugPrint('Guardian settings load failed: $e');
      debugPrintStack(stackTrace: stack);
      _thresholds = AlertThresholds.defaults;
    } finally {
      if (!_disposed) {
        _initialized = true;
        if (!_readyCompleter.isCompleted) {
          _readyCompleter.complete();
        }
        _safeNotify();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Alert thresholds
  // ══════════════════════════════════════════════════════════════════════════

  /// Updates all thresholds in one atomic operation.
  ///
  /// Validates each range. Returns [SettingsChangeResult.invalid] if any
  /// value is out of range — no state is changed in that case.
  Future<SettingsChangeResult> updateThresholds(AlertThresholds next) async {
    if (_disposed) return SettingsChangeResult.error;

    if (!_isValidThresholds(next)) {
      return SettingsChangeResult.invalid;
    }

    if (next == _thresholds) return SettingsChangeResult.success;

    _thresholds = next;
    _safeNotify();

    // Persist.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(AppConstants.keyAlertHrHigh, next.heartRateHigh);
      await prefs.setInt(AppConstants.keyAlertSpo2Low, next.spo2Low);
      await prefs.setDouble(
        AppConstants.keyAlertTempHigh,
        next.temperatureHigh,
      );
      await prefs.setInt(AppConstants.keyAlertBatteryLow, next.batteryLow);
      await prefs.setInt(
        AppConstants.keyAlertBatteryCritical,
        next.batteryCritical,
      );
    } catch (e, stack) {
      debugPrint('Guardian settings persist failed: $e');
      debugPrintStack(stackTrace: stack);
      return SettingsChangeResult.error;
    }

    // Notify the background service so its cached settings refresh.
    BackgroundBridge.notifySettingsChanged();

    return SettingsChangeResult.success;
  }

  /// Updates a single threshold field.
  Future<SettingsChangeResult> setHeartRateHigh(int value) async {
    if (value < 60 || value > 220) {
      return SettingsChangeResult.invalid;
    }
    return updateThresholds(_thresholds.copyWith(heartRateHigh: value));
  }

  Future<SettingsChangeResult> setSpo2Low(int value) async {
    if (value < 70 || value > 100) {
      return SettingsChangeResult.invalid;
    }
    return updateThresholds(_thresholds.copyWith(spo2Low: value));
  }

  Future<SettingsChangeResult> setTemperatureHigh(double value) async {
    if (!value.isFinite || value < 35.0 || value > 42.0) {
      return SettingsChangeResult.invalid;
    }
    return updateThresholds(_thresholds.copyWith(temperatureHigh: value));
  }

  Future<SettingsChangeResult> setBatteryLow(int value) async {
    if (value < 5 || value > 50) {
      return SettingsChangeResult.invalid;
    }
    return updateThresholds(_thresholds.copyWith(batteryLow: value));
  }

  Future<SettingsChangeResult> setBatteryCritical(int value) async {
    if (value < 1 || value > 30) {
      return SettingsChangeResult.invalid;
    }
    return updateThresholds(_thresholds.copyWith(batteryCritical: value));
  }

  /// Restores all thresholds to their defaults.
  Future<SettingsChangeResult> resetThresholds() {
    return updateThresholds(AlertThresholds.defaults);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Health-platform export
  // ══════════════════════════════════════════════════════════════════════════

  /// Enables or disables export to Apple Health / Health Connect.
  ///
  /// When enabling, this prompts the OS for permission and stores the
  /// resulting status.
  Future<SettingsChangeResult> setHealthExportEnabled(bool enabled) async {
    if (_disposed) return SettingsChangeResult.error;
    if (_healthExportEnabled == enabled) {
      return SettingsChangeResult.success;
    }

    final service = HealthExportService.shared();

    try {
      final status = await service.setOptIn(enabled);
      if (_disposed) return SettingsChangeResult.error;

      switch (status) {
        case HealthIntegrationStatus.authorized:
          _healthExportEnabled = true;
          break;
        case HealthIntegrationStatus.disabled:
          _healthExportEnabled = false;
          break;
        case HealthIntegrationStatus.permissionRequired:
          // Preference stored, but OS permission not yet granted. The UI
          // should surface this to the user.
          _healthExportEnabled = false;
          _safeNotify();
          return SettingsChangeResult.invalid;
        case HealthIntegrationStatus.unavailable:
          _healthExportEnabled = false;
          _safeNotify();
          return SettingsChangeResult.unavailable;
        case HealthIntegrationStatus.error:
        case HealthIntegrationStatus.unknown:
          _healthExportEnabled = false;
          _safeNotify();
          return SettingsChangeResult.error;
      }

      _safeNotify();
      return SettingsChangeResult.success;
    } catch (e, stack) {
      debugPrint('Guardian health export setting failed: $e');
      debugPrintStack(stackTrace: stack);
      return SettingsChangeResult.error;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Cloud sync
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> setCloudSyncEnabled(bool enabled) async {
    if (_disposed || _cloudSyncEnabled == enabled) return;

    _cloudSyncEnabled = enabled;
    _safeNotify();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.keyCloudSyncEnabled, enabled);
    } catch (e, stack) {
      debugPrint('Guardian settings persist failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Retention
  // ══════════════════════════════════════════════════════════════════════════

  /// Days of local history to retain. Range: 7 – 365.
  Future<SettingsChangeResult> setRetentionDays(int days) async {
    if (_disposed) return SettingsChangeResult.error;
    if (days < 7 || days > 365) return SettingsChangeResult.invalid;
    if (_retentionDays == days) return SettingsChangeResult.success;

    _retentionDays = days;
    _safeNotify();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(AppConstants.keyRetentionDays, days);
      return SettingsChangeResult.success;
    } catch (e, stack) {
      debugPrint('Guardian settings persist failed: $e');
      debugPrintStack(stackTrace: stack);
      return SettingsChangeResult.error;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Reset (sign-out)
  // ══════════════════════════════════════════════════════════════════════════

  /// Reverts in-memory state to defaults. Does NOT touch prefs.
  ///
  /// Called on sign-out to avoid leaking the previous user's UI state.
  /// The next user's `load()` will re-read their own stored preferences.
  void clearInMemory() {
    if (_disposed) return;
    _thresholds = AlertThresholds.defaults;
    _healthExportEnabled = false;
    _cloudSyncEnabled = true;
    _retentionDays = 90;
    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Internal
  // ══════════════════════════════════════════════════════════════════════════

  bool _isValidThresholds(AlertThresholds t) {
    if (t.heartRateHigh < 60 || t.heartRateHigh > 220) return false;
    if (t.spo2Low < 70 || t.spo2Low > 100) return false;
    if (!t.temperatureHigh.isFinite) return false;
    if (t.temperatureHigh < 35.0 || t.temperatureHigh > 42.0) return false;
    if (t.batteryLow < 5 || t.batteryLow > 50) return false;
    if (t.batteryCritical < 1 || t.batteryCritical > 30) return false;
    if (t.batteryCritical >= t.batteryLow) return false;
    return true;
  }

  AlertThresholds _sanitize(AlertThresholds t) {
    if (_isValidThresholds(t)) return t;
    // Fall back to defaults for any field that is out of range.
    return AlertThresholds(
      heartRateHigh: (t.heartRateHigh >= 60 && t.heartRateHigh <= 220)
          ? t.heartRateHigh
          : AlertThresholds.defaults.heartRateHigh,
      spo2Low: (t.spo2Low >= 70 && t.spo2Low <= 100)
          ? t.spo2Low
          : AlertThresholds.defaults.spo2Low,
      temperatureHigh:
          (t.temperatureHigh.isFinite &&
              t.temperatureHigh >= 35.0 &&
              t.temperatureHigh <= 42.0)
          ? t.temperatureHigh
          : AlertThresholds.defaults.temperatureHigh,
      batteryLow: (t.batteryLow >= 5 && t.batteryLow <= 50)
          ? t.batteryLow
          : AlertThresholds.defaults.batteryLow,
      batteryCritical:
          (t.batteryCritical >= 1 &&
              t.batteryCritical <= 30 &&
              t.batteryCritical < t.batteryLow)
          ? t.batteryCritical
          : AlertThresholds.defaults.batteryCritical,
    );
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Dispose
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }

    super.dispose();
  }
}
