import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../device_terminal_model.dart';
import 'device_terminal_repository.dart';

/// Placeholder UUIDs for the Fluxon hardware device.
///
/// Update these when the real hardware UUIDs are finalized.
class FluxonHardwareUuids {
  /// GATT service UUID advertised by the Fluxon hardware device.
  static final service = Guid('F1DF1001-1234-5678-9ABC-DEF012345678');

  /// TX characteristic — phone writes data TO the device.
  static final tx = Guid('F1DF1002-1234-5678-9ABC-DEF012345678');

  /// RX characteristic — device notifies data TO the phone.
  static final rx = Guid('F1DF1003-1234-5678-9ABC-DEF012345678');
}

/// Concrete [DeviceTerminalRepository] using flutter_blue_plus.
///
/// Handles BLE scanning, connection, service discovery, and raw byte
/// read/write for the external Fluxon hardware device.
class BleDeviceTerminalRepository implements DeviceTerminalRepository {
  final _scanController = StreamController<List<ScannedDevice>>.broadcast();
  final _dataController = StreamController<Uint8List>.broadcast();
  final _statusController =
      StreamController<DeviceConnectionStatus>.broadcast();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription? _scanSub;
  StreamSubscription? _notifySub;
  StreamSubscription? _connectionStateSub;

  @override
  Stream<List<ScannedDevice>> get onScanResults => _scanController.stream;

  @override
  Stream<Uint8List> get onDataReceived => _dataController.stream;

  @override
  Stream<DeviceConnectionStatus> get onConnectionStatusChanged =>
      _statusController.stream;

  @override
  Future<void> startScan() async {
    _statusController.add(DeviceConnectionStatus.scanning);

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      final devices = results
          .map((r) => ScannedDevice(
                id: r.device.remoteId.str,
                name: r.device.platformName,
                rssi: r.rssi,
              ))
          .toList();
      _scanController.add(devices);
    });

    await FlutterBluePlus.startScan(
      withServices: [FluxonHardwareUuids.service],
      timeout: const Duration(seconds: 15),
    );

    // Scan finished (timeout or manual stop) — if not connected, go back to disconnected.
    if (_connectedDevice == null) {
      _statusController.add(DeviceConnectionStatus.disconnected);
    }
  }

  @override
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    _scanSub = null;
  }

  @override
  Future<void> connect(String deviceId) async {
    await stopScan();
    _statusController.add(DeviceConnectionStatus.connecting);

    try {
      final device = BluetoothDevice.fromId(deviceId);
      await device.connect(timeout: const Duration(seconds: 10));

      // Negotiate larger MTU for bigger payloads.
      await device.requestMtu(512);

      // Discover GATT services and find our characteristics.
      final services = await device.discoverServices();
      BluetoothCharacteristic? txChar;
      BluetoothCharacteristic? rxChar;

      for (final service in services) {
        if (service.uuid == FluxonHardwareUuids.service) {
          for (final char in service.characteristics) {
            if (char.uuid == FluxonHardwareUuids.tx) {
              txChar = char;
            } else if (char.uuid == FluxonHardwareUuids.rx) {
              rxChar = char;
            }
          }
          break;
        }
      }

      if (txChar == null || rxChar == null) {
        await device.disconnect();
        _statusController.add(DeviceConnectionStatus.disconnected);
        return;
      }

      _connectedDevice = device;
      _txCharacteristic = txChar;

      // Subscribe to RX notifications.
      await rxChar.setNotifyValue(true);
      _notifySub = rxChar.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          _dataController.add(Uint8List.fromList(value));
        }
      });

      // Monitor disconnection.
      _connectionStateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _cleanup();
          _statusController.add(DeviceConnectionStatus.disconnected);
        }
      });

      _statusController.add(DeviceConnectionStatus.connected);
    } catch (_) {
      _cleanup();
      _statusController.add(DeviceConnectionStatus.disconnected);
    }
  }

  @override
  Future<void> disconnect() async {
    _statusController.add(DeviceConnectionStatus.disconnecting);
    final device = _connectedDevice;
    _cleanup();
    if (device != null) {
      await device.disconnect();
    }
    _statusController.add(DeviceConnectionStatus.disconnected);
  }

  @override
  Future<void> send(Uint8List data) async {
    final char = _txCharacteristic;
    if (char == null) return;
    await char.write(data.toList(), withoutResponse: false);
  }

  void _cleanup() {
    _notifySub?.cancel();
    _notifySub = null;
    _connectionStateSub?.cancel();
    _connectionStateSub = null;
    _connectedDevice = null;
    _txCharacteristic = null;
  }

  @override
  void dispose() {
    _cleanup();
    _scanSub?.cancel();
    _scanController.close();
    _dataController.close();
    _statusController.close();
  }
}
