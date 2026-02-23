import 'dart:async';
import 'dart:typed_data';
import '../device_terminal_model.dart';

/// Abstract interface for BLE device terminal operations.
///
/// Decouples the [DeviceTerminalController] from flutter_blue_plus
/// and BLE GATT specifics. Implementations handle scanning, connection,
/// service/characteristic discovery, and read/write operations.
abstract class DeviceTerminalRepository {
  /// Stream of scanned devices during an active scan.
  Stream<List<ScannedDevice>> get onScanResults;

  /// Stream of incoming data (RX notifications from the device).
  Stream<Uint8List> get onDataReceived;

  /// Stream of connection status changes.
  Stream<DeviceConnectionStatus> get onConnectionStatusChanged;

  /// Start scanning for devices advertising the Fluxon hardware service UUID.
  Future<void> startScan();

  /// Stop scanning.
  Future<void> stopScan();

  /// Connect to a device by its platform ID. Discovers services and subscribes
  /// to the RX characteristic for notifications.
  Future<void> connect(String deviceId);

  /// Disconnect from the currently connected device.
  Future<void> disconnect();

  /// Write raw bytes to the TX characteristic of the connected device.
  Future<void> send(Uint8List data);

  /// Release all resources (subscriptions, connections).
  void dispose();
}
