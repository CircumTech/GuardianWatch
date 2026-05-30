// ─── lib/services/ble_service.dart ───────────────────────────────────────────
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../config/constants.dart';
import '../models/sensor_data.dart';

class BleService {
  BluetoothDevice? _device;
  final _dataController = StreamController<SensorData>.broadcast();
  Stream<SensorData> get dataStream => _dataController.stream;

  // ECG stream for detail screen
  final _ecgController = StreamController<List<double>>.broadcast();
  Stream<List<double>> get ecgStream => _ecgController.stream;

  bool get isConnected => _device != null;

  Future<List<ScanResult>> scanForDevices(
      {Duration timeout = const Duration(seconds: 10)}) async {
    final results = <ScanResult>[];
    await FlutterBluePlus.startScan(timeout: timeout);
    final sub = FlutterBluePlus.scanResults.listen((r) => results.addAll(r));
    await Future.delayed(timeout);
    await FlutterBluePlus.stopScan();
    await sub.cancel();
    return results
        .where((r) => r.device.platformName.contains('GuardianWrist'))
        .toList();
  }

  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await device.connect(autoConnect: false);
    await _subscribeToCharacteristics(device);
  }

  Future<void> _subscribeToCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    for (var svc in services) {
      if (svc.uuid.toString().toUpperCase() != AppConstants.bleServiceUuid) {
        continue;
      }
      for (var char in svc.characteristics) {
        final uuid = char.uuid.toString().toUpperCase();
        if (char.properties.notify) {
          await char.setNotifyValue(true);
          char.onValueReceived.listen((bytes) => _parseBytes(uuid, bytes));
        }
      }
    }
  }

  void _parseBytes(String charUuid, List<int> bytes) {
    final now = DateTime.now();
    if (charUuid == AppConstants.hrCharUuid && bytes.length >= 2) {
      final bpm = (bytes[0] << 8) | bytes[1];
      _dataController.add(SensorData(heartRate: bpm, timestamp: now));
    } else if (charUuid == AppConstants.spo2CharUuid && bytes.isNotEmpty) {
      _dataController.add(SensorData(spo2: bytes[0], timestamp: now));
    } else if (charUuid == AppConstants.tempCharUuid && bytes.length >= 4) {
      final bd = ByteData.sublistView(Uint8List.fromList(bytes));
      final temp = bd.getFloat32(0, Endian.little);
      _dataController.add(SensorData(temperature: temp, timestamp: now));
    } else if (charUuid == AppConstants.ecgCharUuid && bytes.length >= 2) {
      final samples = <double>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final raw = (bytes[i] << 8) | bytes[i + 1];
        samples.add(raw * 0.0024);
      }
      _ecgController.add(samples);
      _dataController.add(SensorData(ecgMv: samples, timestamp: now));
    } else if (charUuid == AppConstants.batteryCharUuid && bytes.isNotEmpty) {
      _dataController.add(SensorData(battery: bytes[0], timestamp: now));
    }
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
  }

  void dispose() {
    _dataController.close();
    _ecgController.close();
    disconnect();
  }
}
