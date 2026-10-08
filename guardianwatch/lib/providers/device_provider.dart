// ════════════════════════════════════════════════════════════════════════════
// lib/providers/device_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// DeviceProvider — device identity, trust state, capabilities, ECG sessions.
//
// Responsibilities:
//   Persist and expose the paired Guardian Watch's identity
//     (device ID, name, hardware revision, firmware version)
//   Track verification / trust state
//     (unverified to provisioning to verified to revoked)
//   Snapshot the connected device's capabilities
//     (which sensors are available)
//   Manage ECG session lifecycle (start / stop / list / delete)
//   Provide a diagnostics snapshot for support
//
// Design rules:
//   BleProvider calls recordConnectedDevice() / recordDisconnected()
//     on connection events. Never the reverse.
//   Device identity is the source of truth. UI reads from here.
//   ECG sessions are stored via LocalDbService — this provider is
//     only the lifecycle manager, not the storage.
//   Verification is a placeholder for the firmware challenge/response
//     handshake. Until firmware supports it, devices stay UNVERIFIED.
//   All notifyListeners() paths are guarded by _disposed.
//

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/constants.dart';
import '../services/ble_service.dart';
import '../services/local_db_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Trust state
// ════════════════════════════════════════════════════════════════════════════

enum DeviceTrustState {
  /// Never seen a device.
  unknown,

  /// Device is known but the authenticated handshake has not run.
  unverified,

  /// Handshake in progress.
  provisioning,

  /// Challenge/response succeeded. Device is trusted.
  verified,

  /// Was trusted, but re-verification failed.
  revoked,
}

// ════════════════════════════════════════════════════════════════════════════
// Capabilities snapshot
// ════════════════════════════════════════════════════════════════════════════

@immutable
class DeviceCapabilities {
  final bool heartRate;
  final bool spo2;
  final bool temperature;
  final bool ecg;
  final bool battery;

  const DeviceCapabilities({
    required this.heartRate,
    required this.spo2,
    required this.temperature,
    required this.ecg,
    required this.battery,
  });

  static const DeviceCapabilities none = DeviceCapabilities(
    heartRate: false,
    spo2: false,
    temperature: false,
    ecg: false,
    battery: false,
  );

  bool get hasAny => heartRate || spo2 || temperature || ecg || battery;

  /// Sensors the technical report marks as mandatory.
  bool get isComplete => heartRate && spo2 && temperature && ecg && battery;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceCapabilities &&
          other.heartRate == heartRate &&
          other.spo2 == spo2 &&
          other.temperature == temperature &&
          other.ecg == ecg &&
          other.battery == battery;

  @override
  int get hashCode => Object.hash(heartRate, spo2, temperature, ecg, battery);

  @override
  String toString() =>
      'DeviceCapabilities(hr: $heartRate, spo2: $spo2, '
      'temp: $temperature, ecg: $ecg, batt: $battery)';
}

// ════════════════════════════════════════════════════════════════════════════
// Diagnostics snapshot
// ════════════════════════════════════════════════════════════════════════════

@immutable
class DeviceDiagnostics {
  final String? deviceId;
  final String? deviceName;
  final String? hardwareRevision;
  final String? firmwareVersion;
  final DeviceTrustState trust;
  final DeviceCapabilities capabilities;
  final DateTime? lastConnectedAt;
  final DateTime? lastVerifiedAt;
  final int totalEcgSessions;

  const DeviceDiagnostics({
    this.deviceId,
    this.deviceName,
    this.hardwareRevision,
    this.firmwareVersion,
    required this.trust,
    required this.capabilities,
    this.lastConnectedAt,
    this.lastVerifiedAt,
    required this.totalEcgSessions,
  });
}

// ════════════════════════════════════════════════════════════════════════════
// Provider
// ════════════════════════════════════════════════════════════════════════════

class DeviceProvider extends ChangeNotifier {
  DeviceProvider();

  // ── Services ──────────────────────────────────────────────────────────────

  final LocalDbService _db = LocalDbService();
  final Uuid _uuid = const Uuid();

  // ── State ─────────────────────────────────────────────────────────────────

  String? _deviceId;
  String? _deviceName;
  String? _hardwareRevision;
  String? _firmwareVersion;

  DeviceTrustState _trust = DeviceTrustState.unknown;
  DeviceCapabilities _capabilities = DeviceCapabilities.none;

  DateTime? _lastConnectedAt;
  DateTime? _lastVerifiedAt;

  int _totalEcgSessions = 0;

  String? _activeEcgSessionId;
  DateTime? _activeEcgSessionStart;

  bool _initialized = false;
  bool _disposed = false;

  final Completer<void> _readyCompleter = Completer<void>();

  // ── Getters ───────────────────────────────────────────────────────────────

  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;
  String? get hardwareRevision => _hardwareRevision;
  String? get firmwareVersion => _firmwareVersion;

  bool get hasPairedDevice => _deviceId != null && _deviceId!.isNotEmpty;

  DeviceTrustState get trust => _trust;
  bool get isVerified => _trust == DeviceTrustState.verified;
  bool get isVerifying => _trust == DeviceTrustState.provisioning;

  DeviceCapabilities get capabilities => _capabilities;

  DateTime? get lastConnectedAt => _lastConnectedAt;
  DateTime? get lastVerifiedAt => _lastVerifiedAt;

  int get totalEcgSessions => _totalEcgSessions;

  bool get hasActiveEcgSession => _activeEcgSessionId != null;
  String? get activeEcgSessionId => _activeEcgSessionId;
  DateTime? get activeEcgSessionStart => _activeEcgSessionStart;

  bool get isInitialized => _initialized;
  bool get isReady => _initialized;

  /// Awaits the initial load from SharedPreferences.
  Future<void> waitUntilReady() => _readyCompleter.future;

  // ══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ══════════════════════════════════════════════════════════════════════════

  /// Loads persisted device identity.
  ///
  /// Idempotent. Call from app bootstrap.
  Future<void> load() async {
    if (_initialized || _disposed) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;

      _deviceId = _nonEmpty(prefs.getString(AppConstants.keyDeviceId));
      _deviceName = _nonEmpty(prefs.getString(AppConstants.keyDeviceName));
      _hardwareRevision = _nonEmpty(
        prefs.getString(AppConstants.keyDeviceHwRev),
      );
      _firmwareVersion = _nonEmpty(
        prefs.getString(AppConstants.keyDeviceFwRev),
      );

      final verified = prefs.getBool(AppConstants.keyDeviceVerified) ?? false;

      _trust = _deviceId == null
          ? DeviceTrustState.unknown
          : (verified
                ? DeviceTrustState.verified
                : DeviceTrustState.unverified);

      await _refreshEcgSessionCount();
    } catch (e, stack) {
      debugPrint('Guardian device load failed: $e');
      debugPrintStack(stackTrace: stack);
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
  // Connection events (called by BleProvider)
  // ══════════════════════════════════════════════════════════════════════════

  /// Records a successful BLE connection.
  ///
  /// Called by [BleProvider] once the underlying link is established and
  /// services have been discovered.
  Future<void> recordConnectedDevice({
    required String deviceId,
    String? deviceName,
    DeviceCapabilities? capabilities,
    String? hardwareRevision,
    String? firmwareVersion,
  }) async {
    if (_disposed) return;

    _deviceId = deviceId;
    _deviceName = deviceName;
    _capabilities = capabilities ?? DeviceCapabilities.none;
    _hardwareRevision = hardwareRevision;
    _firmwareVersion = firmwareVersion;
    _lastConnectedAt = DateTime.now();

    // A newly connected device must be re-verified before it is trusted.
    if (_trust != DeviceTrustState.verified) {
      _trust = DeviceTrustState.unverified;
    }

    await _persistIdentity();

    _safeNotify();
  }

  /// Records a BLE disconnection.
  ///
  /// Keeps identity and trust state; clears the live capability snapshot
  /// because the device is no longer reachable.
  Future<void> recordDisconnected() async {
    if (_disposed) return;

    _capabilities = DeviceCapabilities.none;

    // End an in-flight ECG session if the device disconnected.
    if (_activeEcgSessionId != null) {
      await endEcgSession();
    }

    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Verification
  // ══════════════════════════════════════════════════════════════════════════

  /// Marks the beginning of the authenticated handshake.
  ///
  /// The actual challenge/response runs in firmware. This method is
  /// called by the UI immediately before the handshake so the state
  /// machine reflects "in progress".
  void beginVerification() {
    if (_disposed) return;
    if (_deviceId == null) return;
    if (_trust == DeviceTrustState.provisioning) return;

    _trust = DeviceTrustState.provisioning;
    _safeNotify();
  }

  /// Marks the handshake as successful.
  ///
  /// Call this only after the firmware confirms the challenge/response
  /// result. Until firmware implements the handshake, this should not be
  /// invoked.
  Future<void> completeVerification() async {
    if (_disposed) return;
    if (_deviceId == null) return;

    _trust = DeviceTrustState.verified;
    _lastVerifiedAt = DateTime.now();

    await _persistIdentity();
    _safeNotify();
  }

  /// Marks the handshake as failed or revoked.
  Future<void> revokeVerification() async {
    if (_disposed) return;

    _trust = _deviceId == null
        ? DeviceTrustState.unknown
        : DeviceTrustState.revoked;

    await _persistIdentity();
    _safeNotify();
  }

  /// Forgets the paired device entirely.
  ///
  /// Clears identity, trust state, and capability snapshot. Does NOT
  /// delete ECG sessions — those are user data, removed via
  /// [deleteAllEcgSessions] or account deletion.
  Future<void> forgetDevice() async {
    if (_disposed) return;

    _deviceId = null;
    _deviceName = null;
    _hardwareRevision = null;
    _firmwareVersion = null;
    _trust = DeviceTrustState.unknown;
    _capabilities = DeviceCapabilities.none;
    _lastConnectedAt = null;
    _lastVerifiedAt = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.keyDeviceId);
      await prefs.remove(AppConstants.keyDeviceName);
      await prefs.remove(AppConstants.keyDeviceVerified);
      await prefs.remove(AppConstants.keyDeviceHwRev);
      await prefs.remove(AppConstants.keyDeviceFwRev);
    } catch (e, stack) {
      debugPrint('Guardian forget device persist failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Capabilities
  // ══════════════════════════════════════════════════════════════════════════

  /// Updates the capability snapshot from a live [BleService] instance.
  ///
  /// Called by [BleProvider] after service discovery.
  void updateCapabilitiesFromBle(BleService ble) {
    if (_disposed) return;

    final next = DeviceCapabilities(
      heartRate: ble.hasHeartRate,
      spo2: ble.hasSpO2,
      temperature: ble.hasTemperature,
      ecg: ble.hasEcg,
      battery: ble.hasBattery,
    );

    if (next == _capabilities) return;

    _capabilities = next;
    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ECG session lifecycle
  // ══════════════════════════════════════════════════════════════════════════

  /// Starts a new ECG session.
  ///
  /// Returns the session ID, or null if a session is already active or no
  /// user is signed in.
  Future<String?> startEcgSession({
    double sampleRate = AppConstants.ecgSampleRate,
    String? storagePath,
  }) async {
    if (_disposed) return null;
    if (_activeEcgSessionId != null) return null;

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) return null;

    final id = _uuid.v4();
    final startedAt = DateTime.now();

    try {
      await _db.createEcgSession(
        id: id,
        userId: userId,
        deviceId: _deviceId,
        sampleRate: sampleRate.toInt(),
        storagePath: storagePath,
      );
    } catch (e, stack) {
      debugPrint('Guardian ECG session start failed: $e');
      debugPrintStack(stackTrace: stack);
      return null;
    }

    _activeEcgSessionId = id;
    _activeEcgSessionStart = startedAt;
    _safeNotify();

    return id;
  }

  /// Ends the currently active ECG session.
  ///
  /// [sampleCount], [durationMs], and [signalQuality] are optional and
  /// should be provided by the ECG capture pipeline.
  Future<void> endEcgSession({
    int? sampleCount,
    int? durationMs,
    int? signalQuality,
    String? storagePath,
  }) async {
    if (_disposed) return;

    final id = _activeEcgSessionId;
    if (id == null) return;

    final started = _activeEcgSessionStart;
    final ended = DateTime.now();
    final computedDuration =
        durationMs ??
        (started != null ? ended.difference(started).inMilliseconds : null);

    try {
      await _db.updateEcgSession(
        id: id,
        endedAt: ended,
        sampleCount: sampleCount,
        durationMs: computedDuration,
        signalQuality: signalQuality,
        storagePath: storagePath,
      );
    } catch (e, stack) {
      debugPrint('Guardian ECG session end failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    _activeEcgSessionId = null;
    _activeEcgSessionStart = null;

    await _refreshEcgSessionCount();
    _safeNotify();
  }

  /// Lists ECG sessions for the current user.
  Future<List<Map<String, dynamic>>> listEcgSessions({
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
  }) async {
    if (_disposed) return const [];

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) return const [];

    try {
      return await _db.queryEcgSessions(
        userId: userId,
        from: from,
        to: to,
        limit: limit,
        offset: offset,
      );
    } catch (e, stack) {
      debugPrint('Guardian ECG session list failed: $e');
      debugPrintStack(stackTrace: stack);
      return const [];
    }
  }

  /// Returns a single ECG session's metadata.
  Future<Map<String, dynamic>?> getEcgSessionById(String id) async {
    if (_disposed) return null;

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) return null;

    try {
      return await _db.getEcgSessionById(id, userId: userId);
    } catch (e, stack) {
      debugPrint('Guardian ECG session fetch failed: $e');
      debugPrintStack(stackTrace: stack);
      return null;
    }
  }

  /// Deletes a single ECG session's metadata.
  ///
  /// The caller is responsible for deleting any associated storage file.
  Future<bool> deleteEcgSession(String id) async {
    if (_disposed) return false;

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) return false;

    try {
      final removed = await _db.deleteEcgSession(id, userId: userId);
      if (removed > 0) {
        await _refreshEcgSessionCount();
        _safeNotify();
      }
      return removed > 0;
    } catch (e, stack) {
      debugPrint('Guardian ECG session delete failed: $e');
      debugPrintStack(stackTrace: stack);
      return false;
    }
  }

  /// Returns the current user's unsynced ECG sessions.
  Future<List<Map<String, dynamic>>> getUnsyncedEcgSessions({
    int limit = 50,
  }) async {
    if (_disposed) return const [];

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) return const [];

    try {
      return await _db.getUnsyncedEcgSessions(userId: userId, limit: limit);
    } catch (e, stack) {
      debugPrint('Guardian ECG unsynced fetch failed: $e');
      debugPrintStack(stackTrace: stack);
      return const [];
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Diagnostics
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns a snapshot for support screens / logs.
  DeviceDiagnostics get diagnostics => DeviceDiagnostics(
    deviceId: _deviceId,
    deviceName: _deviceName,
    hardwareRevision: _hardwareRevision,
    firmwareVersion: _firmwareVersion,
    trust: _trust,
    capabilities: _capabilities,
    lastConnectedAt: _lastConnectedAt,
    lastVerifiedAt: _lastVerifiedAt,
    totalEcgSessions: _totalEcgSessions,
  );

  // ══════════════════════════════════════════════════════════════════════════
  // Reset (sign-out)
  // ══════════════════════════════════════════════════════════════════════════

  /// Clears per-user state.
  ///
  /// Device identity is preserved — the device is still paired to the
  /// physical watch. Only the active ECG session is cleared.
  void clearInMemory() {
    if (_disposed) return;

    _activeEcgSessionId = null;
    _activeEcgSessionStart = null;
    _capabilities = DeviceCapabilities.none;
    _totalEcgSessions = 0;

    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Internal
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _persistIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (_deviceId != null) {
        await prefs.setString(AppConstants.keyDeviceId, _deviceId!);
      } else {
        await prefs.remove(AppConstants.keyDeviceId);
      }

      if (_deviceName != null) {
        await prefs.setString(AppConstants.keyDeviceName, _deviceName!);
      } else {
        await prefs.remove(AppConstants.keyDeviceName);
      }

      if (_hardwareRevision != null) {
        await prefs.setString(AppConstants.keyDeviceHwRev, _hardwareRevision!);
      }

      if (_firmwareVersion != null) {
        await prefs.setString(AppConstants.keyDeviceFwRev, _firmwareVersion!);
      }

      await prefs.setBool(
        AppConstants.keyDeviceVerified,
        _trust == DeviceTrustState.verified,
      );
    } catch (e, stack) {
      debugPrint('Guardian device identity persist failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<void> _refreshEcgSessionCount() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) {
      _totalEcgSessions = 0;
      return;
    }

    try {
      final sessions = await _db.queryEcgSessions(userId: userId, limit: 1000);
      _totalEcgSessions = sessions.length;
    } catch (e) {
      debugPrint('Guardian ECG count refresh failed: $e');
      _totalEcgSessions = 0;
    }
  }

  static String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
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
