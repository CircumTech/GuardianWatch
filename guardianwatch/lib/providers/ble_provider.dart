import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/constants.dart';
import '../models/sensor_data.dart';
import '../models/health_record.dart';
import '../services/ble_service.dart';
import '../services/health_export_service.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/connectivity_service.dart';
import '../services/background_service.dart';
import '../services/notification_service.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum BleStatus { idle, scanning, connecting, connected, disconnected, error }

class BleProvider extends ChangeNotifier {
  final BleService _ble = BleService();
  final HealthExportService _health = HealthExportService();
  final ApiService _api = ApiService();
  final LocalDbService _db = LocalDbService();
  final ConnectivityService _connectivity = ConnectivityService();
  final Uuid _uuid = const Uuid();

  BleStatus _status = BleStatus.idle;
  String? _error;
  SensorData? _latest;
  int _pendingUploads = 0;

  final List<ScanResult> _scanResults = [];
  final List<SensorData> _uploadQueue = [];

  StreamSubscription<SensorData>? _dataSub;
  StreamSubscription<bool>? _connectSub;
  Timer? _uploadTimer;

  // Additional fields for corrections
  final ValueNotifier<List<ScanResult>> scanResultsNotifier = ValueNotifier([]);
  String? _lastConnectedDeviceId;
  int _hrHighThreshold = AppConstants.defaultHrHigh;
  int _spo2LowThreshold = AppConstants.defaultSpo2Low;

  // ── Getters ────────────────────────────────────────────────────────────────
  BleStatus get status => _status;
  String? get error => _error;
  SensorData? get latest => _latest;
  int get pendingUploads => _pendingUploads;
  bool get isConnected => _status == BleStatus.connected;
  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  String? get lastConnectedDeviceId => _lastConnectedDeviceId;

  int? get heartRate => _latest?.heartRate;
  int? get spo2 => _latest?.spo2;
  double? get temperature => _latest?.temperature;
  int? get battery => _latest?.battery;
  List<double>? get ecgMv => _latest?.ecgMv;

  // Expose ECG stream from BleService
  Stream<List<double>> get ecgStream => _ble.ecgStream;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  BleProvider() {
    _connectivity.startMonitoring();
    _connectSub = _connectivity.onStatusChange.listen(_onConnectivityChange);
    NotificationService.init();
    _loadLastDeviceId();
  }

  Future<void> _loadLastDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    _lastConnectedDeviceId = prefs.getString('last_device_id');
  }

  // ── BLE Scan & Connect ─────────────────────────────────────────────────────
  Future<void> startScan() async {
    _scanResults.clear();
    scanResultsNotifier.value = [];
    _setStatus(BleStatus.scanning);
    try {
      final results = await _ble.scanForDevices();
      _scanResults.addAll(results);
      scanResultsNotifier.value = List.from(_scanResults);
      _setStatus(BleStatus.idle);
    } catch (e) {
      _setError(e.toString());
    }
  }

  Future<void> connectTo(BluetoothDevice device) async {
    _setStatus(BleStatus.connecting);
    try {
      await _ble.connect(device);
      _lastConnectedDeviceId = device.remoteId.str;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_device_id', _lastConnectedDeviceId!);
      _setStatus(BleStatus.connected);
      _listenToData();
      _startUploadTimer();
      await BackgroundBridge.start();
    } catch (e) {
      _setError(e.toString());
    }
  }

  Future<void> autoReconnect() async {
    if (_lastConnectedDeviceId == null) return;
    // Simplified: trigger scan and try to connect to known device ID
    await startScan();
    // In a real implementation, you'd filter scanResults for the known ID
  }

  Future<void> reconnect() async {
    if (_lastConnectedDeviceId != null) {
      await autoReconnect();
    } else {
      await startScan();
    }
  }

  // ── Data pipeline ──────────────────────────────────────────────────────────
  void _listenToData() {
    _dataSub = _ble.dataStream.listen((incoming) async {
      // Merge with previous composite
      _latest = _merge(_latest, incoming);
      _uploadQueue.add(incoming);

      // Push to background isolate for threshold alerting
      BackgroundBridge.sendSensorData(incoming.toJson());

      // Health export (Apple Health / Google Fit)
      if (incoming.heartRate != null)
        _health.exportHeartRate(incoming.heartRate!, incoming.timestamp);
      if (incoming.spo2 != null)
        _health.exportSpO2(incoming.spo2!, incoming.timestamp);
      if (incoming.temperature != null)
        _health.exportTemperature(incoming.temperature!, incoming.timestamp);

      // Cache locally (always, regardless of connectivity)
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'offline';
      if (incoming.heartRate != null &&
          incoming.spo2 != null &&
          incoming.temperature != null) {
        await _db.insertRecord(HealthRecord(
          id: _uuid.v4(),
          userId: uid,
          heartRate: incoming.heartRate!,
          spo2: incoming.spo2!,
          temperature: incoming.temperature!,
          recordedAt: incoming.timestamp,
        ));
      }

      notifyListeners();
    });
  }

  void _startUploadTimer() {
    _uploadTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_uploadQueue.isEmpty) return;
      final online = await _connectivity.checkNow();
      if (!online) {
        _pendingUploads = _uploadQueue.length;
        notifyListeners();
        return;
      }
      final batch = List<SensorData>.from(_uploadQueue);
      _uploadQueue.clear();
      final ok = await _api.uploadReadings(batch);
      if (!ok) {
        _uploadQueue.insertAll(0, batch);
      }
      _pendingUploads = _uploadQueue.length;
      notifyListeners();
    });
  }

  Future<void> _onConnectivityChange(bool online) async {
    if (online && _uploadQueue.isNotEmpty) {
      final batch = List<SensorData>.from(_uploadQueue);
      _uploadQueue.clear();
      await _api.uploadReadings(batch);
      _pendingUploads = 0;
      notifyListeners();
    }
  }

  // ── Alert thresholds ───────────────────────────────────────────────────────
  void updateAlertThresholds({required int hrHigh, required int spo2Low}) {
    _hrHighThreshold = hrHigh;
    _spo2LowThreshold = spo2Low;
  }

  // ── Disconnect ─────────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    _uploadTimer?.cancel();
    await _dataSub?.cancel();
    await _ble.disconnect();
    await BackgroundBridge.stop();
    await NotificationService.showWatchDisconnected();
    _latest = null;
    _setStatus(BleStatus.disconnected);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  SensorData _merge(SensorData? prev, SensorData next) => SensorData(
        heartRate: next.heartRate ?? prev?.heartRate,
        spo2: next.spo2 ?? prev?.spo2,
        temperature: next.temperature ?? prev?.temperature,
        ecgMv: next.ecgMv ?? prev?.ecgMv,
        battery: next.battery ?? prev?.battery,
        timestamp: next.timestamp,
      );

  void _setStatus(BleStatus s) {
    _status = s;
    _error = null;
    notifyListeners();
  }

  void _setError(String msg) {
    _error = msg;
    _status = BleStatus.error;
    notifyListeners();
  }

  @override
  void dispose() {
    scanResultsNotifier.dispose();
    _connectSub?.cancel();
    _connectivity.stopMonitoring();
    disconnect();
    _ble.dispose();
    super.dispose();
  }
}
