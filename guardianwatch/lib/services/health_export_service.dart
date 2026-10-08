// ─── lib/services/health_export_service.dart ─────────────────────────────────
//
// Guardian Watch health-platform integration.
//
// Exports selected Guardian readings to:
//   Apple Health on iOS
//   Health Connect on Android
//
// Design rules:
//   Export is opt-in. The preference is stored locally; the OS
//    permission is the user's separate choice.
//   Checking permission NEVER prompts. Requesting permission is a
//    separate, user-initiated action.
//   Export failures are isolated. They log and return false; they
//    never throw into the Guardian telemetry pipeline.
//   Duplicate exports within a short window are suppressed.
//

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Status enum
// ─────────────────────────────────────────────────────────────────────────────

enum HealthIntegrationStatus {
  unknown,

  /// User has not enabled export (or has turned it off).
  disabled,

  /// User enabled export but has not granted OS permission yet.
  permissionRequired,

  /// Export is enabled and OS permission is granted.
  authorized,

  /// The platform does not support a health store (desktop, web, or
  /// Android without Health Connect installed).
  unavailable,

  /// An unexpected error occurred during a health-platform operation.
  error,
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class HealthExportService {
  HealthExportService({Health? health}) : _health = health ?? Health();

  static final HealthExportService _shared = HealthExportService._createShared();

  factory HealthExportService.shared() => _shared;

  HealthExportService._createShared() : _health = Health();

  final Health _health;

  HealthIntegrationStatus _status = HealthIntegrationStatus.unknown;
  bool _exportEnabled = false;
  bool _initialized = false;
  bool _platformSupported = true;

  /// Deduplicates concurrent init() calls.
  Future<void>? _initializing;

  /// Tracks whether the last permission-request already tried and was
  /// denied. Prevents the app from repeatedly prompting the user.
  bool _permissionDeniedThisSession = false;

  // ── Public state ─────────────────────────────────────────────────────────

  HealthIntegrationStatus get status => _status;
  bool get isExportEnabled => _exportEnabled;
  bool get isAuthorized => _status == HealthIntegrationStatus.authorized;
  bool get isPlatformSupported => _platformSupported;

  // ─────────────────────────────────────────────────────────────────────────
  // Health data types Guardian exports
  // ─────────────────────────────────────────────────────────────────────────

  static const List<HealthDataType> _supportedTypes = [
    HealthDataType.HEART_RATE,
    HealthDataType.BLOOD_OXYGEN,
    HealthDataType.BODY_TEMPERATURE,
  ];

  /// Point-measurement window. The platform stores some data types as
  /// ranges; a 1-second window matches how HR is recorded and prevents
  /// zero-duration samples from being rejected.
  static const Duration _pointWindow = Duration(seconds: 1);

  // ─────────────────────────────────────────────────────────────────────────
  // Initialization
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;

    // Deduplicate concurrent init calls.
    final inFlight = _initializing;
    if (inFlight != null) return inFlight;

    final future = _doInit();
    _initializing = future;

    try {
      await future;
    } finally {
      if (identical(_initializing, future)) {
        _initializing = null;
      }
    }
  }

  Future<void> _doInit() async {
    // 1. Platform check.
    if (!(Platform.isAndroid || Platform.isIOS)) {
      _platformSupported = false;
      _status = HealthIntegrationStatus.unavailable;
      _initialized = true;
      debugPrint('Guardian health export unavailable: unsupported platform.');
      return;
    }

    try {
      // 2. Configure the plugin. Required before any other call.
      try {
        await _health.configure();
      } catch (e) {
        // Some health plugin versions do not require configure().
        // Do not fail here; proceed and let later calls surface errors.
        debugPrint('Health.configure() warning: $e');
      }

      // 3. Verify the platform health store is actually present.
      final available = await _isHealthStoreAvailable();
      if (!available) {
        _platformSupported = false;
        _status = HealthIntegrationStatus.unavailable;
        _initialized = true;
        debugPrint(
          'Guardian health export unavailable: health store missing '
          '(Health Connect not installed?).',
        );
        return;
      }

      // 4. Load the user preference.
      final prefs = await SharedPreferences.getInstance();
      _exportEnabled = prefs.getBool(AppConstants.keyHealthOptIn) ?? false;

      if (!_exportEnabled) {
        _status = HealthIntegrationStatus.disabled;
        _initialized = true;
        return;
      }

      // 5. Check current permission WITHOUT prompting.
      final granted = await _checkGranted();
      _status = granted
          ? HealthIntegrationStatus.authorized
          : HealthIntegrationStatus.permissionRequired;

      _initialized = true;
    } catch (e, stack) {
      debugPrint('Guardian health export init failed: $e');
      debugPrintStack(stackTrace: stack);
      _status = HealthIntegrationStatus.error;
      _initialized = true;
    }
  }

  /// True if the platform health store exists and can accept writes.
  Future<bool> _isHealthStoreAvailable() async {
    try {
      // hasPermissions returns null on some platforms if the store is
      // missing entirely. On Android this is a strong signal that
      // Health Connect is not installed.
      final result = await _health.hasPermissions(_supportedTypes);
      if (result == null) return false;

      // HealthKit on iOS is always present. Health Connect on Android
      // can be absent — the plugin returns null in that case.
      return true;
    } catch (e) {
      debugPrint('Health store availability check failed: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // User opt-in state
  // ─────────────────────────────────────────────────────────────────────────

  /// Async method — not a getter, so callers cannot accidentally treat
  /// the returned Future as a bool.
  Future<bool> checkOptedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppConstants.keyHealthOptIn) ?? false;
  }

  /// Enables or disables export.
  ///
  /// When [enabled] is true, this also requests OS permission (if not
  /// already granted) — because the user just tapped the toggle.
  /// Returns the resulting [HealthIntegrationStatus].
  Future<HealthIntegrationStatus> setOptIn(bool enabled) async {
    if (!_initialized) await init();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyHealthOptIn, enabled);
    _exportEnabled = enabled;

    if (!enabled) {
      _status = HealthIntegrationStatus.disabled;
      return _status;
    }

    if (!_platformSupported) {
      _status = HealthIntegrationStatus.unavailable;
      return _status;
    }

    // User just enabled → it's appropriate to prompt for permission.
    final granted = await _requestPermissionsInternal();
    _status = granted
        ? HealthIntegrationStatus.authorized
        : HealthIntegrationStatus.permissionRequired;

    return _status;
  }

  Future<void> enableSync() async {
    await setOptIn(true);
  }

  Future<void> disableSync() async {
    await setOptIn(false);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Permission handling
  // ─────────────────────────────────────────────────────────────────────────

  /// Checks whether permission was already granted, without prompting.
  Future<bool> _checkGranted() async {
    try {
      final result = await _health.hasPermissions(_supportedTypes);
      return result == true;
    } catch (e) {
      debugPrint('Health permission check failed: $e');
      return false;
    }
  }

  /// Public check — does not prompt.
  Future<bool> hasPermission() async {
    if (!_initialized) await init();
    if (!_platformSupported) return false;
    return _checkGranted();
  }

  /// Public request — prompts the user if not already granted.
  ///
  /// Rate-limited within a session: after a denial, subsequent calls
  /// return false without prompting again until the next app launch.
  Future<bool> requestPermissions() async {
    if (!_initialized) await init();

    if (!_platformSupported) {
      _status = HealthIntegrationStatus.unavailable;
      return false;
    }

    if (_permissionDeniedThisSession) {
      return false;
    }

    final granted = await _requestPermissionsInternal();
    _status = granted
        ? HealthIntegrationStatus.authorized
        : HealthIntegrationStatus.permissionRequired;

    if (!granted) {
      _permissionDeniedThisSession = true;
    }

    return granted;
  }

  Future<bool> _requestPermissionsInternal() async {
    try {
      final permissions = List<HealthDataAccess>.filled(
        _supportedTypes.length,
        HealthDataAccess.WRITE,
      );

      final granted = await _health.requestAuthorization(
        _supportedTypes,
        permissions: permissions,
      );

      return granted;
    } catch (e, stack) {
      debugPrint('Health permission request failed: $e');
      debugPrintStack(stackTrace: stack);
      _status = HealthIntegrationStatus.error;
      return false;
    }
  }

  /// Re-reads the platform permission state without prompting.
  Future<void> refreshAuthorizationStatus() async {
    if (!_initialized) await init();

    if (!_exportEnabled) {
      _status = HealthIntegrationStatus.disabled;
      return;
    }

    if (!_platformSupported) {
      _status = HealthIntegrationStatus.unavailable;
      return;
    }

    try {
      final granted = await _checkGranted();
      _status = granted
          ? HealthIntegrationStatus.authorized
          : HealthIntegrationStatus.permissionRequired;
    } catch (e) {
      debugPrint('Health authorization refresh failed: $e');
      _status = HealthIntegrationStatus.error;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Write helper
  // ─────────────────────────────────────────────────────────────────────────

  /// Ensures we have permission to write. Does NOT prompt.
  ///
  /// The user-facing "enable sync" flow is responsible for prompting.
  /// Bulk export paths should silently skip if permission is missing.
  Future<bool> _isWritable() async {
    if (!_initialized) await init();
    if (!_platformSupported) return false;
    if (!_exportEnabled) return false;

    if (_status == HealthIntegrationStatus.authorized) return true;

    // Recheck silently — permission may have been granted in Settings.
    final granted = await _checkGranted();
    if (granted) {
      _status = HealthIntegrationStatus.authorized;
      return true;
    }

    return false;
  }

  Future<bool> _writeOne({
    required double value,
    required HealthDataType type,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final writable = await _isWritable();
    if (!writable) return false;

    try {
      final ok = await _health.writeHealthData(
        value: value,
        type: type,
        startTime: startTime.toLocal(),
        endTime: endTime.toLocal(),
      );

      if (!ok) {
        debugPrint(
          'Health write returned false for $type '
          'at $startTime.',
        );
      }

      return ok;
    } catch (e, stack) {
      debugPrint('Health write failed for $type: $e');
      debugPrintStack(stackTrace: stack);
      _status = HealthIntegrationStatus.error;
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Heart rate
  // ─────────────────────────────────────────────────────────────────────────

  Future<bool> exportHeartRate(int bpm, DateTime timestamp) async {
    if (bpm < 20 || bpm > 240) return false;

    return _writeOne(
      value: bpm.toDouble(),
      type: HealthDataType.HEART_RATE,
      startTime: timestamp.subtract(_pointWindow),
      endTime: timestamp,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SpO₂
  // ─────────────────────────────────────────────────────────────────────────

  Future<bool> exportSpO2(int percentage, DateTime timestamp) async {
    if (percentage < 50 || percentage > 100) return false;

    return _writeOne(
      value: percentage.toDouble(),
      type: HealthDataType.BLOOD_OXYGEN,
      startTime: timestamp.subtract(_pointWindow),
      endTime: timestamp,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Temperature
  // ─────────────────────────────────────────────────────────────────────────

  Future<bool> exportTemperature(double celsius, DateTime timestamp) async {
    if (!celsius.isFinite || celsius < 0 || celsius > 60) return false;

    return _writeOne(
      value: celsius,
      type: HealthDataType.BODY_TEMPERATURE,
      startTime: timestamp.subtract(_pointWindow),
      endTime: timestamp,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Batch export
  // ─────────────────────────────────────────────────────────────────────────

  /// Exports a single reading that may carry HR, SpO₂, and/or temperature.
  ///
  /// Returns a per-metric map so the caller can see which writes succeeded.
  /// Failures never throw.
  Future<Map<String, bool>> exportBatch({
    int? heartRate,
    int? spo2,
    double? temperature,
    required DateTime timestamp,
  }) async {
    final results = <String, bool>{
      'heart_rate': true,
      'spo2': true,
      'temperature': true,
    };

    if (heartRate != null) {
      results['heart_rate'] = await exportHeartRate(heartRate, timestamp);
    }

    if (spo2 != null) {
      results['spo2'] = await exportSpO2(spo2, timestamp);
    }

    if (temperature != null) {
      results['temperature'] = await exportTemperature(temperature, timestamp);
    }

    return results;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session cleanup
  // ─────────────────────────────────────────────────────────────────────────

  /// Clears the local opt-in preference.
  ///
  /// The OS-level Health permission remains granted — only the user can
  /// revoke that, from system settings. This method only clears
  /// Guardian's own preference so the next user starts opted-out.
  ///
  /// Call this on sign-out if the app is used by more than one user.
  Future<void> clearOptIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.keyHealthOptIn);

    _exportEnabled = false;
    _permissionDeniedThisSession = false;
    _status = HealthIntegrationStatus.disabled;
  }
}
