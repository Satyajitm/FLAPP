import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart' as ble_p;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../shared/hex_utils.dart';
import '../../shared/logger.dart';
import '../crypto/keys.dart';
import '../crypto/noise_session_manager.dart';
import '../identity/identity_manager.dart';
import '../mesh/deduplicator.dart';
import '../protocol/binary_protocol.dart';
import '../protocol/message_types.dart';
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
  final IdentityManager _identityManager;

  final _packetController = StreamController<FluxonPacket>.broadcast();
  final _peersController = StreamController<List<PeerConnection>>.broadcast();
  final Map<String, BluetoothDevice> _connectedDevices = {};
  final Map<String, PeerConnection> _peerConnections = {};
  final Map<String, BluetoothCharacteristic> _peerCharacteristics = {};
  /// Tracks devices currently being connected to, to prevent duplicate
  /// concurrent connection attempts from overlapping scan results.
  final Set<String> _connectingDevices = {};

  /// Deduplicator to prevent processing the same packet twice (e.g. received
  /// via both central notification and peripheral write callback).
  final MessageDeduplicator _deduplicator;

  /// Noise session manager for per-device encryption.
  late final NoiseSessionManager _noiseSessionManager;

  /// Maps BLE device ID to Fluxon peer ID hex (learned from handshake).
  final Map<String, String> _deviceToPeerHex = {};

  /// Reverse map: Fluxon peer ID hex to BLE device ID.
  final Map<String, String> _peerHexToDevice = {};

  bool _running = false;
  StreamSubscription? _scanSubscription;
  Timer? _scanRestartTimer;

  /// Last time a packet was sent or received. Used to detect idle periods.
  DateTime _lastActivityTimestamp = DateTime.now();

  /// Whether the transport is currently in idle duty-cycle scan mode.
  bool _isInIdleMode = false;

  /// Fires every second to check whether to switch between active/idle modes.
  Timer? _idleCheckTimer;

  /// Controls the OFF phase of the duty cycle (pauses between short scans).
  Timer? _dutyCycleOffTimer;

  /// Fluxon BLE service UUID.
  static const String serviceUuidStr = 'F1DF0001-1234-5678-9ABC-DEF012345678';
  static final Guid serviceUuid = Guid(serviceUuidStr);

  /// Fluxon BLE characteristic UUID for packet exchange.
  static const String packetCharUuidStr =
      'F1DF0002-1234-5678-9ABC-DEF012345678';
  static final Guid packetCharUuid = Guid(packetCharUuidStr);

  BleTransport({
    required Uint8List myPeerId,
    required IdentityManager identityManager,
    this.config = TransportConfig.defaultConfig,
  })  : _myPeerId = myPeerId,
        _identityManager = identityManager,
        _deduplicator = MessageDeduplicator(
          maxAge: const Duration(seconds: 300),
          maxCount: 1024,
        ) {
    // Initialize Noise session manager
    _noiseSessionManager = NoiseSessionManager(
      myStaticPrivKey: _identityManager.privateKey,
      myStaticPubKey: _identityManager.publicKey,
      localSigningPublicKey: _identityManager.signingPublicKey,
    );
  }

  @override
  Uint8List get myPeerId => _myPeerId;

  @override
  bool get isRunning => _running;

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Stream<List<PeerConnection>> get connectedPeers => _peersController.stream;

  void _log(String message) {
    developer.log('[BleTransport] $message', name: 'Fluxon.BLE');
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> startServices() async {
    if (_running) return;
    _running = true;

    _log('Starting BLE services...');

    // Check BLE availability
    if (await FlutterBluePlus.isSupported == false) {
      _log('ERROR: BLE not supported on this device');
      throw UnsupportedError('BLE is not supported on this device');
    }

    _log('BLE is supported');

    // Start both roles in parallel
    await Future.wait([
      _startPeripheral(),
      _startCentral(),
    ]);
  }

  @override
  Future<void> stopServices() async {
    _log('Stopping BLE services...');
    _running = false;
    _idleCheckTimer?.cancel();
    _dutyCycleOffTimer?.cancel();
    _scanRestartTimer?.cancel();
    await _scanSubscription?.cancel();
    await FlutterBluePlus.stopScan();

    // Stop advertising
    try {
      await ble_p.BlePeripheral.stopAdvertising();
      _log('Advertising stopped');
    } catch (e) {
      _log('Error stopping advertising: $e');
    }

    // Disconnect all peers
    for (final device in _connectedDevices.values) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _connectedDevices.clear();
    _peerConnections.clear();
    _peerCharacteristics.clear();
    _deviceToPeerHex.clear();
    _peerHexToDevice.clear();
    _noiseSessionManager.clear();
    _emitPeerUpdate();
  }

  // ---------------------------------------------------------------------------
  // Peripheral role (ble_peripheral) — GATT server + advertising
  // ---------------------------------------------------------------------------

  Future<void> _startPeripheral() async {
    _log('Starting peripheral role (advertising)...');

    try {
      // Request ALL required permissions for Android 12+
      if (await Permission.bluetoothScan.isDenied) {
        _log('Requesting BLUETOOTH_SCAN permission...');
        await Permission.bluetoothScan.request();
      }
      if (await Permission.bluetoothAdvertise.isDenied) {
        _log('Requesting BLUETOOTH_ADVERTISE permission...');
        await Permission.bluetoothAdvertise.request();
      }
      if (await Permission.bluetoothConnect.isDenied) {
        _log('Requesting BLUETOOTH_CONNECT permission...');
        await Permission.bluetoothConnect.request();
      }

      // Also call the plugin's permission helper
      await ble_p.BlePeripheral.askBlePermission();
      _log('BLE permissions granted');

      await ble_p.BlePeripheral.initialize();
      _log('Peripheral initialized');

      ble_p.BlePeripheral.setWriteRequestCallback(
        (deviceId, characteristicId, offset, value) {
          _log('Received write from $deviceId, char=$characteristicId, len=${value?.length}');
          if (value != null) {
            _handleIncomingData(Uint8List.fromList(value), fromDeviceId: deviceId);
          }
          return null;
        },
      );

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
      _log('GATT service added: $serviceUuidStr');

      await ble_p.BlePeripheral.startAdvertising(
        services: [serviceUuidStr],
        localName: 'Fluxon',
      );
      _log('SUCCESS: Advertising started with UUID $serviceUuidStr');

    } catch (e, stack) {
      _log('ERROR starting peripheral: $e\n$stack');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Central role (flutter_blue_plus) — scanning + connecting
  // ---------------------------------------------------------------------------

  Future<void> _startCentral() async {
    _log('Starting central role (scanning)...');

    // Request location permission required for BLE scanning on Android.
    final locationStatus = await Permission.locationWhenInUse.request();
    _log('Location permission: $locationStatus');
    
    if (locationStatus.isDenied || locationStatus.isPermanentlyDenied) {
      _log('ERROR: Location permission denied - BLE scanning will fail');
      throw Exception('Location permission required for BLE scanning');
    }

    // Wait until the Bluetooth adapter is on before scanning.
    _log('Waiting for Bluetooth adapter...');
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first;
    _log('Bluetooth adapter is ON');
    
    _startScanning();
  }

  void _startScanning() {
    _log('Starting scan (unfiltered — will check service after connect)...');

    // Subscribe once to scan results — reused across active/idle mode switches.
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        // Only consider devices advertising our service UUID **or**
        // devices whose local name is "Fluxon" (fallback when Android
        // strips the service UUID from the advertisement).
        final hasService = result.advertisementData.serviceUuids
            .any((u) => u == serviceUuid);
        final hasName =
            result.device.platformName.toLowerCase().contains('fluxon') ||
            (result.advertisementData.advName.toLowerCase().contains('fluxon'));

        if (hasService || hasName) {
          _log('Found Fluxon device: ${result.device.remoteId.str} '
               '(name=${result.device.platformName}, '
               'advName=${result.advertisementData.advName}, '
               'rssi=${result.rssi}, hasService=$hasService)');
          _handleDiscoveredDevice(result);
        }
      }
    });

    // Start in active mode.
    _enterActiveMode();

    // Idle check fires every second to detect activity/inactivity transitions.
    _idleCheckTimer?.cancel();
    _idleCheckTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_running) return;
      final idleSeconds =
          DateTime.now().difference(_lastActivityTimestamp).inSeconds;

      if (!_isInIdleMode && idleSeconds >= config.idleThresholdSeconds) {
        _log('Idle for ${idleSeconds}s — entering duty-cycle scan mode');
        _enterIdleMode();
      } else if (_isInIdleMode && idleSeconds < config.idleThresholdSeconds) {
        _log('Activity detected — returning to active scan mode');
        _enterActiveMode();
      }
    });
  }

  /// Active scan mode: continuous 15-second scans restarted every 18 seconds.
  /// This is the pre-existing behaviour, preserved exactly.
  void _enterActiveMode() {
    if (!_running) return;
    _isInIdleMode = false;
    _dutyCycleOffTimer?.cancel();
    _dutyCycleOffTimer = null;
    _scanRestartTimer?.cancel();

    _log('Active scan mode: 15 s scan / 18 s restart');
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    _scanRestartTimer = Timer.periodic(const Duration(seconds: 18), (_) {
      if (!_running || _isInIdleMode) return;
      _log('Active mode: restarting scan...');
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    });
  }

  /// Idle scan mode: duty-cycled short scans to conserve battery.
  /// Scans for [dutyCycleScanOnMs] ms, then pauses for [dutyCycleScanOffMs] ms,
  /// then repeats — until activity is detected.
  void _enterIdleMode() {
    if (!_running) return;
    _isInIdleMode = true;
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;

    _log('Idle duty-cycle mode: ${config.dutyCycleScanOnMs} ms ON '
        '/ ${config.dutyCycleScanOffMs} ms OFF');
    _runDutyCycle();
  }

  /// Executes one ON→OFF cycle of the duty-cycled scanner and schedules
  /// the next cycle after the OFF period.
  void _runDutyCycle() {
    if (!_running || !_isInIdleMode) return;

    _log('Duty cycle: scan ON for ${config.dutyCycleScanOnMs} ms');
    FlutterBluePlus.startScan(
      timeout: Duration(milliseconds: config.dutyCycleScanOnMs),
    );

    _dutyCycleOffTimer?.cancel();
    _dutyCycleOffTimer = Timer(
      Duration(
        milliseconds: config.dutyCycleScanOnMs + config.dutyCycleScanOffMs,
      ),
      () {
        if (!_running || !_isInIdleMode) return;
        _runDutyCycle();
      },
    );
  }

  Future<void> _handleDiscoveredDevice(ScanResult result) async {
    final deviceId = result.device.remoteId.str;

    // Skip if already connected or already attempting connection.
    if (_connectedDevices.containsKey(deviceId)) return;
    if (_connectingDevices.contains(deviceId)) return;
    if (_connectedDevices.length >= config.maxConnections) {
      _log('Max connections reached, skipping $deviceId');
      return;
    }

    _connectingDevices.add(deviceId);
    _log('Attempting to connect to $deviceId...');

    try {
      await result.device.connect(
        timeout: Duration(milliseconds: config.connectionTimeoutMs),
      );
      _log('SUCCESS: Connected to $deviceId');

      // Negotiate larger MTU for mesh packets (header 78 + payload + sig 64)
      try {
        final mtu = await result.device.requestMtu(512);
        _log('Negotiated MTU: $mtu for $deviceId');
      } catch (e) {
        _log('MTU negotiation failed for $deviceId (using default): $e');
      }

      _log('Discovering services on $deviceId...');
      final services = await result.device.discoverServices();
      _log('Found ${services.length} services on $deviceId');

      final service = services.where((s) => s.uuid == serviceUuid).firstOrNull;
      if (service == null) {
        _log('No Fluxon service on $deviceId — disconnecting');
        for (final s in services) {
          _log('  - Service: ${s.uuid}');
        }
        await result.device.disconnect();
        _connectingDevices.remove(deviceId);
        return;
      }

      _log('Found Fluxon service on $deviceId');
      final char = service.characteristics
          .where((c) => c.uuid == packetCharUuid)
          .firstOrNull;
      if (char == null) {
        _log('ERROR: Characteristic not found on $deviceId — disconnecting');
        await result.device.disconnect();
        _connectingDevices.remove(deviceId);
        return;
      }

      _log('Found characteristic, subscribing to notifications...');
      _peerCharacteristics[deviceId] = char;
      await char.setNotifyValue(true);
      char.onValueReceived.listen((data) {
        _log('Received notification from $deviceId, len=${data.length}');
        _handleIncomingData(Uint8List.fromList(data), fromDeviceId: deviceId);
      });

      _connectedDevices[deviceId] = result.device;
      _peerConnections[deviceId] = PeerConnection(
        peerId: Uint8List(32),
        rssi: result.rssi,
      );

      // Initiate Noise handshake as central (initiator)
      _initiateNoiseHandshake(deviceId);

      result.device.connectionState.listen((state) {
        _log('Device $deviceId state: $state');
        if (state == BluetoothConnectionState.disconnected) {
          _noiseSessionManager.removeSession(deviceId);

          // Clean up device-to-peer ID mappings
          final peerHex = _deviceToPeerHex.remove(deviceId);
          if (peerHex != null) {
            _peerHexToDevice.remove(peerHex);
          }

          _connectedDevices.remove(deviceId);
          _peerConnections.remove(deviceId);
          _peerCharacteristics.remove(deviceId);
          _connectingDevices.remove(deviceId);
          _emitPeerUpdate();
        }
      });
    } catch (e) {
      _log('ERROR connecting to $deviceId: $e');
      _connectingDevices.remove(deviceId);
    }
  }

  // ---------------------------------------------------------------------------
  // Send / broadcast
  // ---------------------------------------------------------------------------

  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async {
    _lastActivityTimestamp = DateTime.now();
    final peerHex = HexUtils.encode(peerId);

    // Look up the BLE device ID for this peer ID
    final deviceId = _peerHexToDevice[peerHex];
    if (deviceId == null) {
      _log('ERROR: No device mapping for peer $peerHex');
      return false;
    }

    final char = _peerCharacteristics[deviceId];
    if (char == null) {
      _log('ERROR: No characteristic for device $deviceId (peer $peerHex)');
      return false;
    }

    try {
      // Encrypt payload if a Noise session is established
      var encodedData = packet.encodeWithSignature();
      if (_noiseSessionManager.hasSession(deviceId)) {
        final ciphertext = _noiseSessionManager.encrypt(encodedData, deviceId);
        if (ciphertext != null) {
          encodedData = ciphertext;
          _log('Encrypted packet for $peerHex');
        }
      }

      await char.write(encodedData, withoutResponse: true);
      _log('Packet sent to $peerHex');
      return true;
    } catch (e) {
      _log('ERROR sending packet to $peerHex: $e');
      return false;
    }
  }

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    _lastActivityTimestamp = DateTime.now();
    final data = packet.encodeWithSignature();
    _log('Broadcasting packet, len=${data.length}');

    // Send via central connections (write to peers' characteristics)
    for (final entry in _peerCharacteristics.entries) {
      try {
        await entry.value.write(data, withoutResponse: true);
        _log('Sent to ${entry.key}');
      } catch (e) {
        _log('Failed to send to ${entry.key}: $e');
      }
    }

    // Also notify via peripheral (GATT server) to any connected centrals
    try {
      await ble_p.BlePeripheral.updateCharacteristic(
        characteristicId: packetCharUuidStr,
        value: data,
      );
      _log('Updated peripheral characteristic');
    } catch (e) {
      _log('Failed to update characteristic: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming data handling (shared by both roles)
  // ---------------------------------------------------------------------------

  Future<void> _handleIncomingData(
    Uint8List data, {
    required String fromDeviceId,
  }) async {
    _lastActivityTimestamp = DateTime.now();
    _log('Handling incoming data from $fromDeviceId, len=${data.length}');

    // Try Noise decryption first if a session is established
    Uint8List packetData = data;
    if (_noiseSessionManager.hasSession(fromDeviceId)) {
      final decrypted = _noiseSessionManager.decrypt(data, fromDeviceId);
      if (decrypted != null) {
        packetData = decrypted;
        _log('Decrypted packet from $fromDeviceId');
      } else {
        // Decryption failed — only allow valid plaintext packets through
        // (broadcasts and handshakes are sent unencrypted even between
        // peers with established Noise sessions).
        final probe = FluxonPacket.decode(data, hasSignature: true) ??
            FluxonPacket.decode(data, hasSignature: false);
        if (probe != null) {
          packetData = data;
          _log('Decryption failed for $fromDeviceId, valid plaintext packet (type=${probe.type})');
        } else {
          // Not a valid plaintext packet either — likely corrupted or
          // a Noise-encrypted packet that failed decryption. Drop it.
          _log('Decryption failed for $fromDeviceId, invalid packet, dropping');
          return;
        }
      }
    }

    // Try decoding with signature first, then without
    var packet = FluxonPacket.decode(packetData, hasSignature: true);
    packet ??= FluxonPacket.decode(packetData, hasSignature: false);
    if (packet == null) {
      _log('Failed to decode packet from $fromDeviceId');
      return;
    }

    // Handle Noise handshake packets specially
    if (packet.type == MessageType.handshake) {
      await _handleHandshakePacket(fromDeviceId, packet);
      return; // Don't emit handshake packets to app layer
    }

    // Check for duplicates
    if (_deduplicator.isDuplicate(packet.packetId)) {
      _log('Duplicate packet, ignoring');
      return;
    }

    _log('Valid packet received from ${HexUtils.encode(packet.sourceId)}');
    _packetController.add(packet);
  }

  Future<void> _handleHandshakePacket(
    String fromDeviceId,
    FluxonPacket packet,
  ) async {
    _log('Processing Noise handshake from $fromDeviceId');

    final responseAndKey = _noiseSessionManager.processHandshakeMessage(
      fromDeviceId,
      packet.payload,
    );

    // If we got a response, send it back
    if (responseAndKey.response != null) {
      final responsePacket = BinaryProtocol.buildPacket(
        type: MessageType.handshake,
        sourceId: _myPeerId,
        payload: responseAndKey.response!,
        ttl: 1,
      );

      final responseData = responsePacket.encodeWithSignature();

      // Send back via the same device
      final char = _peerCharacteristics[fromDeviceId];
      if (char != null) {
        try {
          await char.write(responseData, withoutResponse: true);
          _log('Sent handshake response to $fromDeviceId');
        } catch (e) {
          _log('ERROR: Failed to send handshake response: $e');
        }
      }
    }

    // If handshake is complete, update peer connection
    if (responseAndKey.remotePubKey != null) {
      final remotePeerIdBytes = KeyGenerator.derivePeerId(
        responseAndKey.remotePubKey!,
      );
      final remotePeerIdHex = HexUtils.encode(remotePeerIdBytes);

      _deviceToPeerHex[fromDeviceId] = remotePeerIdHex;
      _peerHexToDevice[remotePeerIdHex] = fromDeviceId;

      // Update the peer connection with the real peer ID and signing key
      final existingConnection = _peerConnections[fromDeviceId];
      if (existingConnection != null) {
        _peerConnections[fromDeviceId] = PeerConnection(
          peerId: remotePeerIdBytes,
          rssi: existingConnection.rssi,
          signingPublicKey: responseAndKey.remoteSigningPublicKey,
        );
      }

      _log('Handshake complete with $fromDeviceId, peer ID = $remotePeerIdHex');
      _emitPeerUpdate();
    }
  }

  Future<void> _initiateNoiseHandshake(String deviceId) async {
    try {
      final message1 = _noiseSessionManager.startHandshake(deviceId);
      final handshakePacket = BinaryProtocol.buildPacket(
        type: MessageType.handshake,
        sourceId: _myPeerId,
        payload: message1,
        ttl: 1, // Never relay handshakes
      );

      final char = _peerCharacteristics[deviceId];
      if (char == null) {
        _log('ERROR: Cannot initiate handshake — no characteristic for $deviceId');
        return;
      }

      final data = handshakePacket.encodeWithSignature();
      await char.write(data, withoutResponse: true);
      _log('Initiated Noise handshake with $deviceId (message 1 sent)');
    } catch (e) {
      _log('ERROR: Failed to initiate Noise handshake with $deviceId: $e');
    }
  }

  void _emitPeerUpdate() {
    _log('Peer update: ${_peerConnections.length} connected');
    _peersController.add(_peerConnections.values.toList());
  }
}
