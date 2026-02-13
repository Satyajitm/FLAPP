import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../protocol/packet.dart';
import 'transport.dart';
import 'transport_config.dart';

/// BLE phone-to-phone transport implementation.
///
/// Uses flutter_blue_plus for BLE central + peripheral roles.
/// Implements the abstract [Transport] interface so mesh logic
/// is decoupled from the radio layer.
class BleTransport extends Transport {
  final TransportConfig config;
  final Uint8List _myPeerId;

  final _packetController = StreamController<FluxonPacket>.broadcast();
  final _peersController = StreamController<List<PeerConnection>>.broadcast();
  final Map<String, BluetoothDevice> _connectedDevices = {};
  final Map<String, PeerConnection> _peerConnections = {};
  final Map<String, BluetoothCharacteristic> _peerCharacteristics = {};

  bool _running = false;
  StreamSubscription? _scanSubscription;

  /// Fluxon BLE service UUID.
  static final Guid serviceUuid = Guid('F1DF0001-1234-5678-9ABC-FLUXONLINK01');

  /// Fluxon BLE characteristic UUID for packet exchange.
  static final Guid packetCharUuid = Guid('F1DF0002-1234-5678-9ABC-FLUXONLINK01');

  BleTransport({
    required Uint8List myPeerId,
    this.config = TransportConfig.defaultConfig,
  }) : _myPeerId = myPeerId;

  @override
  Uint8List get myPeerId => _myPeerId;

  @override
  bool get isRunning => _running;

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Stream<List<PeerConnection>> get connectedPeers => _peersController.stream;

  @override
  Future<void> startServices() async {
    if (_running) return;
    _running = true;

    // Check BLE availability
    if (await FlutterBluePlus.isSupported == false) {
      throw UnsupportedError('BLE is not supported on this device');
    }

    // Start scanning for other Fluxon devices
    _startScanning();
  }

  @override
  Future<void> stopServices() async {
    _running = false;
    await _scanSubscription?.cancel();
    await FlutterBluePlus.stopScan();

    // Disconnect all peers
    for (final device in _connectedDevices.values) {
      await device.disconnect();
    }
    _connectedDevices.clear();
    _peerConnections.clear();
    _peerCharacteristics.clear();
    _emitPeerUpdate();
  }

  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async {
    final peerHex = peerId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final char = _peerCharacteristics[peerHex];
    if (char == null) return false;

    try {
      await char.write(packet.encodeWithSignature(), withoutResponse: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    final data = packet.encodeWithSignature();
    for (final entry in _peerCharacteristics.entries) {
      try {
        await entry.value.write(data, withoutResponse: true);
      } catch (_) {
        // Best-effort broadcast; skip failed peers
      }
    }
  }

  void _startScanning() {
    FlutterBluePlus.startScan(
      withServices: [serviceUuid],
      timeout: Duration(milliseconds: config.scanIntervalMs),
      continuousUpdates: true,
    );

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _handleDiscoveredDevice(result);
      }
    });
  }

  Future<void> _handleDiscoveredDevice(ScanResult result) async {
    final deviceId = result.device.remoteId.str;
    if (_connectedDevices.containsKey(deviceId)) return;
    if (_connectedDevices.length >= config.maxConnections) return;

    try {
      await result.device.connect(
        timeout: Duration(milliseconds: config.connectionTimeoutMs),
      );
      _connectedDevices[deviceId] = result.device;

      // Set up notification for incoming packets and cache characteristic
      final services = await result.device.discoverServices();
      final service = services.where((s) => s.uuid == serviceUuid).firstOrNull;
      if (service != null) {
        final char = service.characteristics
            .where((c) => c.uuid == packetCharUuid)
            .firstOrNull;
        if (char != null) {
          _peerCharacteristics[deviceId] = char;
          await char.setNotifyValue(true);
          char.onValueReceived.listen((data) {
            _handleIncomingData(Uint8List.fromList(data));
          });
        }
      }

      // Track peer connection with a placeholder peer ID.
      // The real cryptographic peer ID will be populated after a
      // Noise handshake reveals the remote static public key.
      _peerConnections[deviceId] = PeerConnection(
        peerId: Uint8List(32), // placeholder until Noise handshake
        rssi: result.rssi,
      );
      _emitPeerUpdate();

      // Listen for disconnection
      result.device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevices.remove(deviceId);
          _peerConnections.remove(deviceId);
          _peerCharacteristics.remove(deviceId);
          _emitPeerUpdate();
        }
      });
    } catch (_) {
      // Connection failed; will retry on next scan
    }
  }

  void _handleIncomingData(Uint8List data) {
    final packet = FluxonPacket.decode(data);
    if (packet != null) {
      _packetController.add(packet);
    }
  }

  void _emitPeerUpdate() {
    _peersController.add(_peerConnections.values.toList());
  }
}
