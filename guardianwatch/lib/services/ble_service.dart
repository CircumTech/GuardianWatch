// ─── lib/services/ble_service.dart ───────────────────────────────────────────

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/constants.dart';
import '../models/sensor_data.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Typed exceptions
// ─────────────────────────────────────────────────────────────────────────────

class BleException implements Exception {
  final String message;
  final Object? cause;

  const BleException(this.message, {this.cause});

  @override
  String toString() => 'BleException: $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// BLE Service
// ─────────────────────────────────────────────────────────────────────────────

class BleService {
  BleService();

  BluetoothDevice? _device;

  BluetoothCharacteristic? _hrCharacteristic;
  BluetoothCharacteristic? _spo2Characteristic;
  BluetoothCharacteristic? _temperatureCharacteristic;
  BluetoothCharacteristic? _ecgCharacteristic;
  BluetoothCharacteristic? _batteryCharacteristic;

  final StreamController<SensorData> _dataController =
      StreamController<SensorData>.broadcast();

  final StreamController<List<double>> _ecgController =
      StreamController<List<double>>.broadcast();

  final StreamController<BluetoothConnectionState> _connectionController =
      StreamController<BluetoothConnectionState>.broadcast();

  Stream<SensorData> get dataStream => _dataController.stream;
  Stream<List<double>> get ecgStream => _ecgController.stream;
  Stream<BluetoothConnectionState> get connectionStream =>
      _connectionController.stream;

  BluetoothDevice? get device => _device;
  bool get isConnected => _device?.isConnected ?? false;
  String? get connectedDeviceId => _device?.remoteId.str;
  String? get deviceName => _device?.platformName;

  // Which sensors are currently available on the connected watch.
  bool get hasHeartRate => _hrCharacteristic != null;
  bool get hasSpO2 => _spo2Characteristic != null;
  bool get hasTemperature => _temperatureCharacteristic != null;
  bool get hasEcg => _ecgCharacteristic != null;
  bool get hasBattery => _batteryCharacteristic != null;

  // Characteristic subscriptions are explicitly retained.
  final List<StreamSubscription<List<int>>> _characteristicSubscriptions = [];

  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  // Reconnect state
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _userInitiatedDisconnect = false;

  bool _disposed = false;

  // ═════════════════════════════════════════════════════════════════════════
  // SCAN
  // ═════════════════════════════════════════════════════════════════════════

  Future<List<ScanResult>> scanForDevices({Duration? timeout}) async {
    if (_disposed) {
      throw const BleException('BleService has already been disposed.');
    }

    final scanTimeout = timeout ?? AppConstants.bleScanTimeout;

    final resultsById = <String, ScanResult>{};

    StreamSubscription<List<ScanResult>>? scanSubscription;

    try {
      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final device = result.device;

          final serviceMatch = result.advertisementData.serviceUuids.any(
            (uuid) =>
                uuid.str.toUpperCase() ==
                BleConstants.serviceUuid.toUpperCase(),
          );

          final name = device.platformName.isNotEmpty
              ? device.platformName
              : result.advertisementData.advName;

          final nameMatch = name.toLowerCase().contains(
            AppConstants.guardianDeviceNamePrefix.toLowerCase(),
          );

          if (serviceMatch || nameMatch) {
            resultsById[device.remoteId.str] = result;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: scanTimeout);

      await Future<void>.delayed(scanTimeout);

      await FlutterBluePlus.stopScan();

      final results = resultsById.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

      return results;
    } finally {
      await scanSubscription?.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {
        // Ignore scan-stop errors during cleanup.
      }
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // CONNECT
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> connect(BluetoothDevice device, {Duration? timeout}) async {
    if (_disposed) {
      throw const BleException('BleService has already been disposed.');
    }

    final connectTimeout = timeout ?? AppConstants.bleConnectionTimeout;

    // Cancel any pending reconnect from a previous session.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _userInitiatedDisconnect = false;

    if (_device != null && _device!.remoteId != device.remoteId) {
      await disconnect();
    }

    _device = device;

    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();

    _connectionSubscription = device.connectionState.listen(
      (state) => _handleConnectionState(device, state),
      onError: (Object error) {
        debugPrint('Guardian BLE connection stream error: $error');
      },
    );

    try {
      await device.connect(
        autoConnect: false,
        timeout: connectTimeout,
        mtu: BleConstants.targetMtu,
        //  REQUIRED FOR COMMERCIAL RELEASE:
        //   Obtain a flutter_blue_plus commercial license and use:
        //     license: License.commercial,
        //   Shipping with License.nonprofit in a commercial product
        //   violates the flutter_blue_plus license terms.
        license: License.nonprofit,
      );

      await _waitForConnected(device, timeout: connectTimeout);
      await _discoverAndSubscribe(device);
    } catch (e) {
      await _cancelCharacteristicSubscriptions();

      try {
        await device.disconnect();
      } catch (_) {}

      _device = null;
      throw BleException('Failed to connect to Guardian Watch.', cause: e);
    }
  }

  Future<void> _waitForConnected(
    BluetoothDevice device, {
    required Duration timeout,
  }) async {
    if (device.isConnected) return;

    try {
      await device.connectionState
          .where((state) => state == BluetoothConnectionState.connected)
          .first
          .timeout(timeout);
    } on TimeoutException catch (e) {
      throw BleException(
        'Timed out waiting for Guardian Watch BLE connection.',
        cause: e,
      );
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // CONNECTION STATE + AUTO RECONNECT
  // ═════════════════════════════════════════════════════════════════════════

  void _handleConnectionState(
    BluetoothDevice device,
    BluetoothConnectionState state,
  ) {
    if (_disposed) return;

    _connectionController.add(state);
    debugPrint('Guardian BLE state: $state');

    if (state == BluetoothConnectionState.disconnected) {
      _clearCharacteristics();

      // Successful session to reset attempt counter.
      if (_reconnectAttempts > 0) {
        _reconnectAttempts = 0;
      }

      if (!_userInitiatedDisconnect) {
        _scheduleReconnect(device);
      }
    } else if (state == BluetoothConnectionState.connected) {
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
  }

  void _scheduleReconnect(BluetoothDevice device) {
    if (_disposed) return;
    if (_reconnectAttempts >= AppConstants.maxBleReconnectAttempts) {
      debugPrint('Guardian BLE reconnect attempts exhausted.');
      return;
    }

    _reconnectTimer?.cancel();

    _reconnectAttempts++;

    final delay = AppConstants.bleReconnectDelay * _reconnectAttempts;

    debugPrint(
      'Scheduling Guardian BLE reconnect '
      '(attempt $_reconnectAttempts) in ${delay.inSeconds}s.',
    );

    _reconnectTimer = Timer(delay, () async {
      if (_disposed || _userInitiatedDisconnect) return;

      try {
        await device.connect(
          autoConnect: false,
          timeout: AppConstants.bleConnectionTimeout,
          mtu: BleConstants.targetMtu,
          license: License.nonprofit,
        );

        await _waitForConnected(
          device,
          timeout: AppConstants.bleConnectionTimeout,
        );

        await _discoverAndSubscribe(device);
      } catch (e) {
        debugPrint('Guardian BLE reconnect failed: $e');
        _scheduleReconnect(device);
      }
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  // SERVICE DISCOVERY
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    final services = await device.discoverServices();

    BluetoothService? guardianService;

    for (final service in services) {
      if (service.uuid.str.toUpperCase() ==
          BleConstants.serviceUuid.toUpperCase()) {
        guardianService = service;
        break;
      }
    }

    if (guardianService == null) {
      throw const BleException('Guardian Watch service was not found.');
    }

    _clearCharacteristics();

    for (final characteristic in guardianService.characteristics) {
      final uuid = characteristic.uuid.str.toUpperCase();

      if (uuid == BleConstants.hrCharUuid.toUpperCase()) {
        _hrCharacteristic = characteristic;
      } else if (uuid == BleConstants.spo2CharUuid.toUpperCase()) {
        _spo2Characteristic = characteristic;
      } else if (uuid == BleConstants.tempCharUuid.toUpperCase()) {
        _temperatureCharacteristic = characteristic;
      } else if (uuid == BleConstants.ecgCharUuid.toUpperCase()) {
        _ecgCharacteristic = characteristic;
      } else if (uuid == BleConstants.batteryCharUuid.toUpperCase()) {
        _batteryCharacteristic = characteristic;
      }
    }

    _logMissingCharacteristics();
    await _subscribeToAvailableCharacteristics(device);
  }

  void _logMissingCharacteristics() {
    final missing = <String>[
      if (_hrCharacteristic == null) 'heart rate',
      if (_spo2Characteristic == null) 'SpO2',
      if (_temperatureCharacteristic == null) 'temperature',
      if (_ecgCharacteristic == null) 'ECG',
      if (_batteryCharacteristic == null) 'battery',
    ];

    if (missing.isNotEmpty) {
      debugPrint(
        'Guardian Watch missing characteristics: ${missing.join(', ')}',
      );
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // SUBSCRIBE
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _subscribeToAvailableCharacteristics(
    BluetoothDevice device,
  ) async {
    final characteristics = <BluetoothCharacteristic>[
      if (_hrCharacteristic != null) _hrCharacteristic!,
      if (_spo2Characteristic != null) _spo2Characteristic!,
      if (_temperatureCharacteristic != null) _temperatureCharacteristic!,
      if (_ecgCharacteristic != null) _ecgCharacteristic!,
      if (_batteryCharacteristic != null) _batteryCharacteristic!,
    ];

    for (final characteristic in characteristics) {
      if (!characteristic.properties.notify &&
          !characteristic.properties.indicate) {
        debugPrint(
          'Guardian characteristic ${characteristic.uuid} '
          'does not support notifications/indications.',
        );
        continue;
      }

      final subscription = characteristic.onValueReceived.listen(
        (bytes) {
          if (_disposed || !device.isConnected) return;
          _parseBytes(characteristic.uuid.str, bytes);
        },
        onError: (Object error) {
          debugPrint('BLE characteristic error ${characteristic.uuid}: $error');
        },
      );

      _characteristicSubscriptions.add(subscription);

      // FlutterBluePlus ties subscription to the device's disconnect lifecycle.
      device.cancelWhenDisconnected(subscription);

      await characteristic.setNotifyValue(true);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // PACKET DECODING
  // ═════════════════════════════════════════════════════════════════════════

  void _parseBytes(String charUuid, List<int> bytes) {
    if (bytes.isEmpty) return;

    final uuid = charUuid.toUpperCase();
    final now = DateTime.now();

    try {
      if (uuid == BleConstants.hrCharUuid.toUpperCase()) {
        _parseHeartRate(bytes, now);
      } else if (uuid == BleConstants.spo2CharUuid.toUpperCase()) {
        _parseSpO2(bytes, now);
      } else if (uuid == BleConstants.tempCharUuid.toUpperCase()) {
        _parseTemperature(bytes, now);
      } else if (uuid == BleConstants.ecgCharUuid.toUpperCase()) {
        _parseECG(bytes, now);
      } else if (uuid == BleConstants.batteryCharUuid.toUpperCase()) {
        _parseBattery(bytes, now);
      }
    } catch (e, stack) {
      // TODO: route to structured error logger (Sentry/Crashlytics).
      debugPrint('Failed to parse Guardian BLE packet $uuid: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ── Heart rate (uint16, big-endian) ──────────────────────────────────────

  void _parseHeartRate(List<int> bytes, DateTime timestamp) {
    if (bytes.length < BleConstants.heartRatePacketBytes) return;

    final bpm = (bytes[0] << 8) | bytes[1];

    if (bpm < 20 || bpm > 240) return;

    _dataController.add(SensorData(heartRate: bpm, timestamp: timestamp));
  }

  // ── SpO2 (uint8 percent) ─────────────────────────────────────────────────

  void _parseSpO2(List<int> bytes, DateTime timestamp) {
    if (bytes.isEmpty) return;

    final value = bytes.first;

    if (value < 50 || value > 100) return;

    _dataController.add(SensorData(spo2: value, timestamp: timestamp));
  }

  // ── Temperature ──────────────────────────────────────────────────────────

  void _parseTemperature(List<int> bytes, DateTime timestamp) {
    if (bytes.length < BleConstants.temperaturePacketBytes) return;

    final buffer = ByteData.sublistView(Uint8List.fromList(bytes));
    final temperature = buffer.getFloat32(0, Endian.little);

    if (!temperature.isFinite || temperature < 0 || temperature > 60) return;

    _dataController.add(
      SensorData(temperature: temperature, timestamp: timestamp),
    );
  }

  // ── ECG ──────────────────────────────────────────────────────────────────

  void _parseECG(List<int> bytes, DateTime timestamp) {
    if (bytes.length < BleConstants.minimumEcgPacketBytes) return;

    final samples = <double>[];

    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final raw = ((bytes[i] << 8) | bytes[i + 1]).toSigned(16);

      final millivolts = raw * BleConstants.ecgMillivoltsPerCount;

      if (!millivolts.isFinite) continue;

      samples.add(millivolts);
    }

    if (samples.isEmpty) return;

    _ecgController.add(samples);
    _dataController.add(SensorData(ecgMv: samples, timestamp: timestamp));
  }

  // ── Battery (uint8 percent) ──────────────────────────────────────────────

  void _parseBattery(List<int> bytes, DateTime timestamp) {
    if (bytes.isEmpty) return; // ← FIX: was missing
    if (bytes.length < BleConstants.batteryPacketBytes) return;

    final battery = bytes.first;

    if (battery < 0 || battery > 100) return;

    _dataController.add(SensorData(battery: battery, timestamp: timestamp));
  }

  // ═════════════════════════════════════════════════════════════════════════
  // MANUAL READS
  // ═════════════════════════════════════════════════════════════════════════

  Future<int?> readHeartRate() async {
    final c = _hrCharacteristic;
    if (c == null) return null;

    final bytes = await c.read();
    if (bytes.length < BleConstants.heartRatePacketBytes) return null;

    final bpm = (bytes[0] << 8) | bytes[1];
    if (bpm < 20 || bpm > 240) return null;

    return bpm;
  }

  Future<int?> readSpO2() async {
    final c = _spo2Characteristic;
    if (c == null) return null;

    final bytes = await c.read();
    if (bytes.isEmpty) return null;

    final value = bytes.first;
    if (value < 50 || value > 100) return null;

    return value;
  }

  Future<double?> readTemperature() async {
    final c = _temperatureCharacteristic;
    if (c == null) return null;

    final bytes = await c.read();
    if (bytes.length < BleConstants.temperaturePacketBytes) return null;

    final buffer = ByteData.sublistView(Uint8List.fromList(bytes));
    final temperature = buffer.getFloat32(0, Endian.little);

    if (!temperature.isFinite || temperature < 0 || temperature > 60) {
      return null;
    }

    return temperature;
  }

  Future<int?> readBattery() async {
    final c = _batteryCharacteristic;
    if (c == null) return null;

    final bytes = await c.read();
    if (bytes.isEmpty) return null;

    final value = bytes.first;
    if (value < 0 || value > 100) return null;

    return value;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // DISCONNECT
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> disconnect() async {
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final device = _device;
    if (device == null) return;

    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    try {
      await device.disconnect();
    } catch (e) {
      debugPrint('Guardian BLE disconnect error: $e');
    }

    _clearCharacteristics();
    _device = null;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // CLEANUP
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _cancelCharacteristicSubscriptions() async {
    for (final subscription in _characteristicSubscriptions) {
      try {
        await subscription.cancel();
      } catch (_) {}
    }
    _characteristicSubscriptions.clear();
  }

  void _clearCharacteristics() {
    _hrCharacteristic = null;
    _spo2Characteristic = null;
    _temperatureCharacteristic = null;
    _ecgCharacteristic = null;
    _batteryCharacteristic = null;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // DISPOSE
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    try {
      await _device?.disconnect();
    } catch (_) {}

    _clearCharacteristics();
    _device = null;

    await _dataController.close();
    await _ecgController.close();
    await _connectionController.close();
  }
}
