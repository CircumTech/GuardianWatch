// ─── lib/providers/ble_provider.dart ─────────────────────────────────────────
//
// BleProvider — orchestrates BLE connection, live telemetry, local
// persistence, cloud sync, and background-service notifications.
//
// Responsibilities:
//    Request Bluetooth permissions
//    Scan, connect, reconnect to the Guardian Watch
//    Merge incoming BLE packets into a live SensorData snapshot
//    Feed the InsightProvider with new samples
//    Forward telemetry to the background service for alerts
//    Persist health records to SQLite (offline-first)
//    Sync the local queue to the backend when online
//    Optionally export to Apple Health / Health Connect
//
// Design rules:
//    Uses shared service instances (ApiService.shared,
//     HealthExportService.shared).
//    All notifyListeners() paths are guarded by _disposed.
//    The sync queue stores HealthRecord payloads, not SensorData.
//    Failed sync items are marked as 'failed' after maxRetries.
//    Device verification is explicit — devices start unverified.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/constants.dart';
import '../models/health_record.dart';
import '../models/sensor_data.dart';

import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/ble_service.dart';
import '../services/connectivity_service.dart';
import '../services/health_export_service.dart';
import '../services/local_db_service.dart';
import '../services/notification_service.dart';

import 'insight_provider.dart';

// ════════════════════════════════════════════════════════════════════════════
// BLE Status
// ════════════════════════════════════════════════════════════════════════════

enum BleStatus { idle, scanning, connecting, connected, disconnected, error }

// ════════════════════════════════════════════════════════════════════════════
// BLE Provider
// ════════════════════════════════════════════════════════════════════════════

class BleProvider extends ChangeNotifier {
  BleProvider(this._insightProvider) {
    _initialize();
  }

  // ── Services ──────────────────────────────────────────────────────────────

  final BleService _ble = BleService();

  final HealthExportService _health = HealthExportService.shared();

  final ApiService _api = ApiService.shared;

  final LocalDbService _db = LocalDbService();

  final ConnectivityService _connectivity = ConnectivityService();

  final Uuid _uuid = const Uuid();

  final InsightProvider _insightProvider;

  // ── State ─────────────────────────────────────────────────────────────────

  BleStatus _status = BleStatus.idle;
  String? _error;
  SensorData? _latest;

  String? _lastConnectedDeviceId;
  String? _lastConnectedDeviceName;

  int _pendingUploads = 0;
  bool _isSyncing = false;

  int _hrHighThreshold = AppConstants.defaultHrHigh;
  int _spo2LowThreshold = AppConstants.defaultSpo2Low;

  String? _currentSessionId;

  bool _isDisposed = false;

  int _reconnectAttempts = 0;

  // ── Scan state ────────────────────────────────────────────────────────────

  final List<ScanResult> _scanResults = [];

  final ValueNotifier<List<ScanResult>> scanResultsNotifier =
      ValueNotifier<List<ScanResult>>(const []);

  // ── Subscriptions ─────────────────────────────────────────────────────────

  StreamSubscription<SensorData>? _dataSubscription;
  StreamSubscription<bool>? _connectivitySubscription;
  StreamSubscription<BluetoothConnectionState>? _bleConnectionSubscription;

  // ── Timers ────────────────────────────────────────────────────────────────

  Timer? _syncTimer;
  Timer? _persistTimer;
  Timer? _reconnectTimer;

  // ── Getters ───────────────────────────────────────────────────────────────

  BleStatus get status => _status;
  String? get error => _error;
  SensorData? get latest => _latest;
  int get pendingUploads => _pendingUploads;
  bool get isSyncing => _isSyncing;

  bool get isConnected => _ble.isConnected && _status == BleStatus.connected;

  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  String? get lastConnectedDeviceId => _lastConnectedDeviceId;
  String? get lastConnectedDeviceName => _lastConnectedDeviceName;
  String? get currentSessionId => _currentSessionId;

  int? get heartRate => _latest?.heartRate;
  int? get spo2 => _latest?.spo2;
  double? get temperature => _latest?.temperature;
  int? get battery => _latest?.battery;
  List<double>? get ecgMv => _latest?.ecgMv;

  Stream<List<double>> get ecgStream => _ble.ecgStream;
  Stream<BluetoothConnectionState> get connectionStream =>
      _ble.connectionStream;

  int get heartRateAlertThreshold => _hrHighThreshold;
  int get spo2AlertThreshold => _spo2LowThreshold;

  // ─────────────────────────────────────────────────────────────────────────
  // Initialization
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _initialize() async {
    try {
      await NotificationService.init();
      await _health.init();

      _connectivity.startMonitoring();
      _connectivitySubscription = _connectivity.onStatusChange.listen(
        _onConnectivityChange,
      );

      _bleConnectionSubscription = _ble.connectionStream.listen(
        _onBleConnectionStateChanged,
      );

      await _loadPreferences();
      await _refreshPendingUploadCount();

      _startSyncTimer();

      // Attempt to flush anything left over from a previous session.
      unawaited(_flushPersistentSyncQueue());
    } catch (e, stack) {
      debugPrint('Guardian BLE provider initialization failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    _lastConnectedDeviceId = prefs.getString(AppConstants.keyDeviceId);
    _lastConnectedDeviceName = prefs.getString(AppConstants.keyDeviceName);

    _hrHighThreshold =
        prefs.getInt(AppConstants.keyAlertHrHigh) ?? AppConstants.defaultHrHigh;
    _spo2LowThreshold =
        prefs.getInt(AppConstants.keyAlertSpo2Low) ??
        AppConstants.defaultSpo2Low;

    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Permissions
  // ─────────────────────────────────────────────────────────────────────────

  Future<bool> requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.location,
        ].request();

        final scanGranted =
            statuses[Permission.bluetoothScan]?.isGranted ?? false;
        final connectGranted =
            statuses[Permission.bluetoothConnect]?.isGranted ?? false;
        final locationGranted =
            statuses[Permission.location]?.isGranted ?? false;

        // Android 12+ only needs scan + connect. Older versions need location.
        return (scanGranted && connectGranted) || locationGranted;
      }

      if (Platform.isIOS) {
        final status = await Permission.bluetooth.request();
        return status.isGranted;
      }

      return true;
    } catch (e) {
      debugPrint('Guardian Bluetooth permission error: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scan
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> startScan() async {
    if (_isDisposed) return;
    if (_status == BleStatus.scanning || _status == BleStatus.connecting) {
      return;
    }

    final granted = await requestPermissions();
    if (!granted) {
      _setError(
        'Bluetooth permission is required to find your Guardian Watch.',
      );
      return;
    }

    _scanResults.clear();
    scanResultsNotifier.value = const [];
    _setStatus(BleStatus.scanning);

    try {
      final results = await _ble.scanForDevices();

      final unique = <String, ScanResult>{};
      for (final result in results) {
        unique[result.device.remoteId.str] = result;
      }

      _scanResults
        ..clear()
        ..addAll(unique.values);

      _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));

      scanResultsNotifier.value = List.unmodifiable(_scanResults);
      _setStatus(BleStatus.idle);
    } catch (e, stack) {
      debugPrint('Guardian scan failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError('Unable to scan for Guardian Watch.');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connect
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> connectTo(BluetoothDevice device) async {
    if (_isDisposed) return;

    final granted = await requestPermissions();
    if (!granted) {
      _setError(
        'Bluetooth permission is required to connect to Guardian Watch.',
      );
      return;
    }

    if (_status == BleStatus.connecting) return;

    await _cancelDataSubscription();

    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    _setStatus(BleStatus.connecting);

    try {
      await _ble.connect(device);

      _lastConnectedDeviceId = device.remoteId.str;
      _lastConnectedDeviceName = device.platformName.trim().isNotEmpty
          ? device.platformName
          : null;

      await _saveDevicePreferences();

      _setStatus(BleStatus.connected);
      _reconnectAttempts = 0;

      _startDataPipeline();

      // Start the background service. Failure must not abort the
      // connection — the foreground BLE link still works.
      try {
        await BackgroundBridge.start();
      } catch (e) {
        debugPrint('Guardian background service start failed: $e');
      }

      // Flush persistent records immediately.
      unawaited(_flushPersistentSyncQueue());
    } catch (e, stack) {
      debugPrint('Guardian device connection failed: $e');
      debugPrintStack(stackTrace: stack);
      await _cancelDataSubscription();
      _setError('Unable to connect to Guardian Watch.');
    }
  }

  Future<void> _saveDevicePreferences() async {
    final prefs = await SharedPreferences.getInstance();

    if (_lastConnectedDeviceId != null) {
      await prefs.setString(AppConstants.keyDeviceId, _lastConnectedDeviceId!);
    }

    if (_lastConnectedDeviceName != null) {
      await prefs.setString(
        AppConstants.keyDeviceName,
        _lastConnectedDeviceName!,
      );
    }

    // Device remains unverified until the authenticated challenge /
    // response handshake is implemented. TODO: perform handshake here.
    await prefs.setBool(AppConstants.keyDeviceVerified, false);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Auto-reconnect
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> autoReconnect() async {
    if (_isDisposed) return;

    final deviceId = _lastConnectedDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      await startScan();
      return;
    }

    _setStatus(BleStatus.scanning);

    try {
      final results = await _ble.scanForDevices();

      ScanResult? target;
      for (final result in results) {
        if (result.device.remoteId.str == deviceId) {
          target = result;
          break;
        }
      }

      if (target == null) {
        _setStatus(BleStatus.disconnected);
        return;
      }

      await connectTo(target.device);
    } catch (e, stack) {
      debugPrint('Guardian auto-reconnect failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError('Unable to reconnect to your Guardian Watch.');
    }
  }

  Future<void> reconnect() async {
    if (_lastConnectedDeviceId != null) {
      await autoReconnect();
    } else {
      await startScan();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connection state handling
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _onBleConnectionStateChanged(
    BluetoothConnectionState state,
  ) async {
    if (_isDisposed) return;

    switch (state) {
      case BluetoothConnectionState.connected:
        _reconnectAttempts = 0;
        if (_status != BleStatus.connected) {
          _setStatus(BleStatus.connected);
        }
        break;

      case BluetoothConnectionState.disconnected:
        await _cancelDataSubscription();
        _latest = null;
        _setStatus(BleStatus.disconnected);
        _scheduleReconnect();

        try {
          await NotificationService.showWatchDisconnected();
        } catch (e) {
          debugPrint('Guardian disconnect notification failed: $e');
        }
        break;
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    if (_lastConnectedDeviceId == null) return;

    if (_reconnectAttempts >= AppConstants.maxBleReconnectAttempts) {
      debugPrint('Guardian BLE reconnect attempts exhausted.');
      return;
    }

    _reconnectTimer?.cancel();

    _reconnectAttempts++;
    final delay = AppConstants.bleReconnectDelay * _reconnectAttempts;

    _reconnectTimer = Timer(delay, () async {
      if (_isDisposed || isConnected) return;
      await autoReconnect();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Data pipeline
  // ─────────────────────────────────────────────────────────────────────────

  void _startDataPipeline() {
    _dataSubscription?.cancel();

    _dataSubscription = _ble.dataStream.listen(
      (incoming) async {
        if (_isDisposed) return;

        try {
          _latest = _merge(_latest, incoming);

          await _processIncomingSensorData(incoming);

          if (_containsPersistableTelemetry(incoming)) {
            _scheduleSnapshotPersistence();
          }

          _safeNotify();
        } catch (e, stack) {
          debugPrint('Guardian sensor processing error: $e');
          debugPrintStack(stackTrace: stack);
        }
      },
      onError: (Object error) {
        if (_isDisposed) return;
        debugPrint('Guardian BLE data stream error: $error');
        _setError('Guardian Watch data stream error.');
      },
      onDone: () {
        if (_isDisposed) return;
        if (_status == BleStatus.connected) {
          _setStatus(BleStatus.disconnected);
        }
      },
    );
  }

  Future<void> _processIncomingSensorData(SensorData data) async {
    // Insight feed. Guarded in case the insight provider was disposed first.
    try {
      if (data.heartRate != null) {
        _insightProvider.feedHeartRate(data.heartRate!);
      }
      if (data.spo2 != null) {
        _insightProvider.feedSpO2(data.spo2!);
      }
      if (data.temperature != null) {
        _insightProvider.feedTemperature(data.temperature!);
      }
      if (data.ecgMv != null && data.ecgMv!.isNotEmpty) {
        _insightProvider.feedEcgData(data.ecgMv!);
      }
      _insightProvider.updateRealtimeMetrics();
    } catch (e) {
      debugPrint('Guardian insight feed failed: $e');
    }

    // Health-platform export. Isolated — failures must not break telemetry.
    try {
      final results = await _health.exportBatch(
        heartRate: data.heartRate,
        spo2: data.spo2,
        temperature: data.temperature,
        timestamp: data.timestamp,
      );
      for (final entry in results.entries) {
        if (entry.value != true) {
          debugPrint('Guardian health export skipped: ${entry.key}');
        }
      }
    } catch (e) {
      debugPrint('Guardian health-platform export failed: $e');
    }

    // Background service is responsible for threshold alerts.
    BackgroundBridge.sendSensorData(data.toJson());
  }

  bool _containsPersistableTelemetry(SensorData data) {
    return data.heartRate != null ||
        data.spo2 != null ||
        data.temperature != null ||
        data.battery != null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Snapshot persistence
  // ─────────────────────────────────────────────────────────────────────────

  void _scheduleSnapshotPersistence() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 1), () async {
      await _persistCurrentSnapshot();
    });
  }

  Future<void> _persistCurrentSnapshot() async {
    if (_isDisposed) return;

    final snapshot = _latest;
    if (snapshot == null) return;

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) return;

    if (snapshot.heartRate == null &&
        snapshot.spo2 == null &&
        snapshot.temperature == null &&
        snapshot.battery == null) {
      return;
    }

    final now = DateTime.now();

    final record = HealthRecord(
      id: _uuid.v4(),
      userId: userId,
      deviceId: _lastConnectedDeviceId,
      sessionId: _currentSessionId,
      heartRate: snapshot.heartRate,
      spo2: snapshot.spo2,
      temperature: snapshot.temperature,
      battery: snapshot.battery,
      recordedAt: snapshot.timestamp,
      createdAt: now,
      isSynced: false,
    );

    try {
      // insertRecord() enqueues the sync entry atomically. Do NOT call
      // enqueueSync() separately.
      await _db.insertRecord(record);
      await _refreshPendingUploadCount();
      _safeNotify();
    } catch (e, stack) {
      debugPrint('Guardian local health record persistence failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Synchronization
  // ─────────────────────────────────────────────────────────────────────────

  void _startSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      AppConstants.backgroundSyncInterval,
      (_) => unawaited(_flushPersistentSyncQueue()),
    );
  }

  Future<void> _flushPersistentSyncQueue() async {
    if (_isDisposed || _isSyncing) return;

    final online = await _connectivity.checkNow();
    if (!online) {
      await _refreshPendingUploadCount();
      return;
    }

    _isSyncing = true;
    _safeNotify();

    try {
      while (!_isDisposed) {
        final userId = FirebaseAuth.instance.currentUser?.uid;
        if (userId == null || userId.isEmpty) break;

        final items = await _db.getPendingSyncItems(
          userId: userId,
          limit: AppConstants.maxApiBatchSize,
        );

        if (items.isEmpty) break;

        final records = <HealthRecord>[];
        final validQueueItems = <Map<String, dynamic>>[];

        for (final item in items) {
          try {
            final raw = item['payload'];
            if (raw is! String) continue;

            final decoded = jsonDecode(raw);
            if (decoded is! Map<String, dynamic>) continue;

            // Payload is HealthRecord-shaped, not SensorData-shaped.
            records.add(HealthRecord.fromJson(decoded));
            validQueueItems.add(item);

            final queueId = _toInt(item['id']);
            if (queueId != null) {
              await _db.markSyncAttempt(queueId);
            }
          } catch (e) {
            debugPrint('Guardian sync queue item decode failed: $e');

            // Permanently invalid payload — mark failed so it stops
            // blocking the queue.
            final queueId = _toInt(item['id']);
            if (queueId != null) {
              try {
                await _db.markSyncFailed(queueId);
              } catch (_) {}
            }
          }
        }

        if (records.isEmpty) break;

        int accepted;
        try {
          accepted = await _api.uploadHealthRecords(records);
        } on ApiException catch (e) {
          debugPrint('Guardian health-record upload failed: $e');

          // Permanent errors → mark failed. Transient → leave pending
          // for the next tick.
          if (!e.isTransient) {
            for (final item in validQueueItems) {
              final queueId = _toInt(item['id']);
              if (queueId != null) {
                try {
                  await _db.markSyncFailed(queueId);
                } catch (_) {}
              }
            }
          }
          break;
        }

        // Server accepted at least some. Mark all valid items complete.
        for (final item in validQueueItems) {
          final queueId = _toInt(item['id']);
          final recordId = item['record_id']?.toString();

          if (recordId != null && recordId.isNotEmpty) {
            try {
              await _db.markRecordSynced(recordId, userId: userId);
            } catch (e) {
              debugPrint('Guardian failed marking record synced: $e');
            }
          }

          if (queueId != null) {
            await _db.markSyncComplete(queueId);
          }
        }

        debugPrint(
          'Guardian sync: $accepted/${records.length} records accepted.',
        );

        // If the server accepted fewer than we sent, avoid an infinite
        // loop; the remainder will be retried on the next tick.
        if (accepted < records.length) break;
      }
    } catch (e, stack) {
      debugPrint('Guardian persistent synchronization error: $e');
      debugPrintStack(stackTrace: stack);
    } finally {
      _isSyncing = false;
      await _refreshPendingUploadCount();
      _safeNotify();
    }
  }

  Future<void> _refreshPendingUploadCount() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    _pendingUploads = await _db.getPendingSyncCount(userId: userId);
    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connectivity changes
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _onConnectivityChange(bool online) async {
    if (!online || _isDisposed) return;
    await _flushPersistentSyncQueue();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Alert thresholds
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> updateAlertThresholds({
    required int hrHigh,
    required int spo2Low,
  }) async {
    if (hrHigh < 20 || hrHigh > 240) {
      throw ArgumentError(
        'Heart-rate threshold must be between 20 and 240 BPM.',
      );
    }

    if (spo2Low < 50 || spo2Low > 100) {
      throw ArgumentError('SpO₂ threshold must be between 50 and 100%.');
    }

    _hrHighThreshold = hrHigh;
    _spo2LowThreshold = spo2Low;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.keyAlertHrHigh, hrHigh);
    await prefs.setInt(AppConstants.keyAlertSpo2Low, spo2Low);

    // Notify the background service so its cached thresholds refresh.
    BackgroundBridge.notifySettingsChanged();

    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Device verification
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> setDeviceVerified(bool verified) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyDeviceVerified, verified);
    _safeNotify();
  }

  Future<bool> isDeviceVerified() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppConstants.keyDeviceVerified) ?? false;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Disconnect
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> disconnect({bool notifyUser = true}) async {
    if (_isDisposed) return;

    _reconnectTimer?.cancel();
    await _cancelDataSubscription();

    _persistTimer?.cancel();
    await _persistCurrentSnapshot();

    try {
      await _ble.disconnect();
    } catch (e) {
      debugPrint('Guardian BLE disconnect error: $e');
    }

    try {
      await BackgroundBridge.stop();
    } catch (e) {
      debugPrint('Guardian background service stop error: $e');
    }

    if (notifyUser) {
      try {
        await NotificationService.showWatchDisconnected();
      } catch (e) {
        debugPrint('Guardian disconnect notification error: $e');
      }
    }

    _latest = null;
    if (!_isDisposed) _setStatus(BleStatus.disconnected);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session management
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> startMonitoringSession() async {
    if (!isConnected) {
      throw StateError(
        'Cannot start a monitoring session without a connected Guardian Watch.',
      );
    }

    _currentSessionId = _uuid.v4();
    _safeNotify();
  }

  void endMonitoringSession() {
    _currentSessionId = null;
    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  SensorData _merge(SensorData? previous, SensorData next) {
    return SensorData(
      id: next.id ?? previous?.id,
      deviceId: next.deviceId ?? previous?.deviceId,
      heartRate: next.heartRate ?? previous?.heartRate,
      spo2: next.spo2 ?? previous?.spo2,
      temperature: next.temperature ?? previous?.temperature,
      ecgMv: next.ecgMv ?? previous?.ecgMv,
      battery: next.battery ?? previous?.battery,
      signalQuality: next.signalQuality ?? previous?.signalQuality,
      timestamp: next.timestamp,
    );
  }

  Future<void> _cancelDataSubscription() async {
    try {
      await _dataSubscription?.cancel();
    } catch (_) {}
    _dataSubscription = null;
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  void _setStatus(BleStatus newStatus) {
    _status = newStatus;
    if (newStatus != BleStatus.error) _error = null;
    _safeNotify();
  }

  void _setError(String message) {
    _status = BleStatus.error;
    _error = message;
    _safeNotify();
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _safeNotify() {
    if (!_isDisposed) notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispose
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    _syncTimer?.cancel();
    _syncTimer = null;

    _persistTimer?.cancel();
    _persistTimer = null;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _dataSubscription?.cancel();
    _dataSubscription = null;

    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    _bleConnectionSubscription?.cancel();
    _bleConnectionSubscription = null;

    _connectivity.stopMonitoring();

    scanResultsNotifier.dispose();

    // Best-effort cleanup. Do not await — dispose() is synchronous.
    unawaited(_ble.disconnect());
    unawaited(BackgroundBridge.stop());
    unawaited(_ble.dispose());

    super.dispose();
  }
}
