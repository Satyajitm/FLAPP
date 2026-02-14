import 'dart:async';
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart' as ble_p;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../mesh/deduplicator.dart';
import '../protocol/packet.dart';
import 'transport.dart';
import 'transport_config.dart';

/// BLE phone-to-phone transport with dual-role support.
///
/// **Central role** (flutter_blue_plus): scans for peers advertising the Fluxon
/// service, connects, subscribes to notifications, writes packets.
///
/// **Peripheral role** (ble_peripheral): advertises the Fluxon service UUID,
/// runs a GATT server, accepts incoming writes from remote centrals.
///
/// Both roles run simultaneously so two phones can discover each other
/// regardless of who starts scanning first.
class BleTransport extends Transport {
  final TransportConfig config;
  final Uint8List _myPeerId;

  final _packetController = StreamController<FluxonPacket>.broadcast();
  final _peersController = StreamController<List<PeerConnection>>.broadcast();
  final Map<String, BluetoothDevice> _connectedDevices = {};
  final Map<String, PeerConnection> _peerConnections = {};
  final Map<String, BluetoothCharacteristic> _peerCharacteristics = {};

  /// Deduplicator to prevent processing the same packet twice (e.g. received
  /// via both central notification and peripheral write callback).
  final MessageDeduplicator _deduplicator;

  bool _running = false;
  StreamSubscription? _scanSubscription;
  Timer? _scanRestartTimer;

  /// Fluxon BLE service UUID.
  static const String serviceUuidStr = 'F1DF0001-1234-5678-9ABC-DEF012345678';
  static final Guid serviceUuid = Guid(serviceUuidStr);

  /// Fluxon BLE characteristic UUID for packet exchange.
  static const String packetCharUuidStr =
      'F1DF0002-1234-5678-9ABC-DEF012345678';
  static final Guid packetCharUuid = Guid(packetCharUuidStr);

  BleTransport({
    required Uint8List myPeerId,
    this.config = TransportConfig.defaultConfig,
  })  : _myPeerId = myPeerId,
        _deduplicator = MessageDeduplicator(
          maxAge: const Duration(seconds: 300),
          maxCount: 1024,
        );

  @override
  Uint8List get myPeerId => _myPeerId;

  @override
  bool get isRunning => _running;

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Stream<List<PeerConnection>> get connectedPeers => _peersController.stream;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> startServices() async {
    if (_running) return;
    _running = true;

    // Check BLE availability
    if (await FlutterBluePlus.isSupported == false) {
      throw UnsupportedError('BLE is not supported on this device');
    }

    // Start both roles in parallel
    await Future.wait([
      _startPeripheral(),
      _startCentral(),
    ]);
  }

  @override
  Future<void> stopServices() async {
    _running = false;
    _scanRestartTimer?.cancel();
    await _scanSubscription?.cancel();
    await FlutterBluePlus.stopScan();

    // Stop advertising
    try {
      await ble_p.BlePeripheral.stopAdvertising();
    } catch (_) {}

    // Disconnect all peers
    for (final device in _connectedDevices.values) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _connectedDevices.clear();
    _peerConnections.clear();
    _peerCharacteristics.clear();
    _emitPeerUpdate();
  }

  // ---------------------------------------------------------------------------
  // Peripheral role (ble_peripheral) — GATT server + advertising
  // ---------------------------------------------------------------------------

  Future<void> _startPeripheral() async {
    // Request BLE permissions (BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE)
    // before attempting to open a GATT server — required on Android 12+.
    await ble_p.BlePeripheral.askBlePermission();

    // Initialize the peripheral manager
    await ble_p.BlePeripheral.initialize();

    // Handle incoming writes from remote centrals
    ble_p.BlePeripheral.setWriteRequestCallback(
      (deviceId, characteristicId, offset, value) {
        if (value != null) {
          _handleIncomingData(Uint8List.fromList(value));
        }
        return null;
      },
    );

    // Add our GATT service with a writable+notifiable characteristic
    await ble_p.BlePeripheral.addService(
      ble_p.BleService(
        uuid: serviceUuidStr,
        primary: true,
        characteristics: [
          ble_p.BleCharacteristic(
            uuid: packetCharUuidStr,
            properties: [
              ble_p.CharacteristicProperties.write.index,
              ble_p.CharacteristicProperties.writeWithoutResponse.index,
              ble_p.CharacteristicProperties.notify.index,
              ble_p.CharacteristicProperties.read.index,
            ],
            permissions: [
              ble_p.AttributePermissions.readable.index,
              ble_p.AttributePermissions.writeable.index,
            ],
          ),
        ],
      ),
    );

    // Start advertising our service UUID so other phones discover us
    await ble_p.BlePeripheral.startAdvertising(
      services: [serviceUuidStr],
      localName: 'Fluxon',
    );
  }

  // ---------------------------------------------------------------------------
  // Central role (flutter_blue_plus) — scanning + connecting
  // ---------------------------------------------------------------------------

  Future<void> _startCentral() async {
    // Wait until the Bluetooth adapter is on before scanning.
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first;
    _startScanning();
  }

  void _startScanning() {
    FlutterBluePlus.startScan(
      withServices: [serviceUuid],
      timeout: Duration(milliseconds: config.scanIntervalMs),
    );

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _handleDiscoveredDevice(result);
      }
    });

    // Restart scan periodically since it times out
    _scanRestartTimer?.cancel();
    _scanRestartTimer = Timer.periodic(
      Duration(milliseconds: config.scanIntervalMs + 500),
      (_) {
        if (!_running) return;
        FlutterBluePlus.startScan(
          withServices: [serviceUuid],
          timeout: Duration(milliseconds: config.scanIntervalMs),
        );
      },
    );
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

      // Discover the Fluxon GATT service and characteristic
      final services = await result.device.discoverServices();
      final service = services.where((s) => s.uuid == serviceUuid).firstOrNull;
      if (service != null) {
        final char = service.characteristics
            .where((c) => c.uuid == packetCharUuid)
            .firstOrNull;
        if (char != null) {
          _peerCharacteristics[deviceId] = char;
          // Subscribe to notifications (receive data from this peer)
          await char.setNotifyValue(true);
          char.onValueReceived.listen((data) {
            _handleIncomingData(Uint8List.fromList(data));
          });
        }
      }

      // Track peer connection
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

  // ---------------------------------------------------------------------------
  // Send / broadcast
  // ---------------------------------------------------------------------------

  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async {
    final peerHex =
        peerId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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

    // Send via central connections (write to peers' characteristics)
    for (final entry in _peerCharacteristics.entries) {
      try {
        await entry.value.write(data, withoutResponse: true);
      } catch (_) {
        // Best-effort broadcast; skip failed peers
      }
    }

    // Also notify via peripheral (GATT server) to any connected centrals
    try {
      await ble_p.BlePeripheral.updateCharacteristic(
        characteristicId: packetCharUuidStr,
        value: data,
      );
    } catch (_) {
      // Best-effort; no connected centrals yet
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming data handling (shared by both roles)
  // ---------------------------------------------------------------------------

  void _handleIncomingData(Uint8List data) {
    final packet = FluxonPacket.decode(data);
    if (packet == null) return;

    // Deduplicate: skip if we already processed this packet
    if (_deduplicator.isDuplicate(packet.packetId)) return;

    _packetController.add(packet);
  }

  void _emitPeerUpdate() {
    _peersController.add(_peerConnections.values.toList());
  }
}
