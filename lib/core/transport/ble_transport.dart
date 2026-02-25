import 'dart:async';
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart' as ble_p;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../shared/hex_utils.dart';
import '../../shared/logger.dart';
import '../crypto/keys.dart';
import '../crypto/noise_session_manager.dart';
import '../crypto/signatures.dart';
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

  /// Negotiated MTU per BLE device ID. Defaults to 23 (BLE minimum) when
  /// negotiation fails. Used to warn when packets may exceed the link MTU.
  final Map<String, int> _deviceMtu = {};

  /// Per-device last-packet timestamps for rate limiting (H3).
  /// Limits incoming BLE notifications to [_minPacketIntervalMs] ms per device.
  final Map<String, DateTime> _lastPacketTime = {};

  /// Minimum interval between packets from the same device (20 packets/sec max).
  static const int _minPacketIntervalMs = 50;

  /// Tracks devices that have connected to us in our peripheral (GATT server) role,
  /// mapped to their last-write timestamp for time-based eviction (HIGH-2).
  /// Used to enforce [config.maxConnections] on peripheral-side (M4).
  final Map<String, DateTime> _peripheralClients = {};

  /// Set of peripheral client device IDs that have completed a Noise handshake,
  /// allowing encrypted GATT notifications to be sent (CRIT-1).
  final Set<String> _authenticatedPeripheralClients = {};

  /// Global packet counter for cross-device rate limiting (HIGH-1).
  /// Tracks total packets received per second across all devices.
  int _globalPacketCount = 0;
  DateTime _globalRateWindowStart = DateTime.now();
  static const int _maxGlobalPacketsPerSecond = 100;

  /// Timer for periodic peripheral client eviction (HIGH-2).
  Timer? _peripheralClientCleanupTimer;

  /// Periodic timer for handshake timeouts on peripheral clients (MED-7).
  Timer? _handshakeTimeoutTimer;

  /// Tracks when each peripheral client connected for handshake timeout (MED-7).
  final Map<String, DateTime> _peripheralClientConnectedAt = {};

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
    SecureLogger.debug(message, category: 'BLE');
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
    _peripheralClientCleanupTimer?.cancel();
    _handshakeTimeoutTimer?.cancel();
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
    _deviceMtu.clear();
    _lastPacketTime.clear();
    _peripheralClients.clear();
    _authenticatedPeripheralClients.clear();
    _peripheralClientConnectedAt.clear();
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
          // M4: Track peripheral clients with timestamps for eviction (HIGH-2).
          final now = DateTime.now();
          if (!_peripheralClients.containsKey(deviceId)) {
            // New peripheral client — enforce connection limit.
            if (_peripheralClients.length >= config.maxConnections) {
              _log('Peripheral connection limit reached — ignoring write from $deviceId');
              return null;
            }
            _peripheralClientConnectedAt[deviceId] = now;
          }
          _peripheralClients[deviceId] = now; // Update last-write time
          _log('Received write, char=$characteristicId, len=${value?.length}');
          if (value != null) {
            _handleIncomingData(Uint8List.fromList(value), fromDeviceId: deviceId);
          }
          return null;
        },
      );

      // HIGH-2: Periodically evict peripheral clients that haven't written
      // in 60 seconds (stale connections that never disconnected cleanly).
      _peripheralClientCleanupTimer?.cancel();
      _peripheralClientCleanupTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _evictStalePeripheralClients(),
      );

      // MED-7: Periodically enforce handshake timeout for peripheral clients.
      _handshakeTimeoutTimer?.cancel();
      _handshakeTimeoutTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _checkHandshakeTimeouts(),
      );

      await ble_p.BlePeripheral.addService(
        ble_p.BleService(
          uuid: serviceUuidStr,
          primary: true,
          characteristics: [
            ble_p.BleCharacteristic(
              uuid: packetCharUuidStr,
              // MED-2: Only expose write and notify properties.
              // Removing 'read'/'readable' prevents passive observers from
              // polling the last characteristic value without subscribing.
              properties: [
                ble_p.CharacteristicProperties.write.index,
                ble_p.CharacteristicProperties.writeWithoutResponse.index,
                ble_p.CharacteristicProperties.notify.index,
              ],
              permissions: [
                ble_p.AttributePermissions.writeable.index,
              ],
            ),
          ],
        ),
      );
      _log('GATT service added: $serviceUuidStr');

      // H1: Do not broadcast a localName — advertising only the service UUID
      // prevents passive tracking of Fluxon users by app name.
      await ble_p.BlePeripheral.startAdvertising(
        services: [serviceUuidStr],
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
        // NOTE: The name match is used only as a discovery hint to attempt a
        // connection. It confers NO authentication or elevated trust — actual
        // authentication is performed via the Noise XX handshake after connection,
        // and GATT service UUID verification happens before any data exchange.
        final hasService = result.advertisementData.serviceUuids
            .any((u) => u == serviceUuid);
        final hasName =
            result.device.platformName.toLowerCase().contains('fluxon') ||
            (result.advertisementData.advName.toLowerCase().contains('fluxon'));

        if (hasService || hasName) {
          _log('Found candidate device (rssi=${result.rssi}, hasService=$hasService, hasName=$hasName)');
          _handleDiscoveredDevice(result);
        }
      }
    });

    // Start in active mode.
    _enterActiveMode();

    // Idle check fires every 10s — sufficient for a 30s idle threshold.
    _idleCheckTimer?.cancel();
    _idleCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
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

  /// Active scan mode: 14-second scans restarted every 14.5 seconds.
  /// The 0.5 s overlap budget eliminates the previous 3 s blind window.
  void _enterActiveMode() {
    if (!_running) return;
    _isInIdleMode = false;
    _dutyCycleOffTimer?.cancel();
    _dutyCycleOffTimer = null;
    _scanRestartTimer?.cancel();

    _log('Active scan mode: 14 s scan / 14.5 s restart');
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 14));

    _scanRestartTimer = Timer.periodic(const Duration(milliseconds: 14500), (_) {
      if (!_running || _isInIdleMode) return;
      _log('Active mode: restarting scan...');
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 14));
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
    _log('Attempting to connect...');

    // HIGH-7: Use try/finally to ensure _connectingDevices is always cleaned up.
    try {
      await result.device.connect(
        timeout: Duration(milliseconds: config.connectionTimeoutMs),
      );
      _log('SUCCESS: Connected');

      // Negotiate larger MTU for mesh packets (header 78 + payload + sig 64)
      try {
        final mtu = await result.device.requestMtu(512);
        _deviceMtu[deviceId] = mtu;
        _log('Negotiated MTU: $mtu');
        if (mtu < 256) {
          _log('WARNING: MTU $mtu < 256 — large packets may be silently truncated');
        }
      } catch (e) {
        // L1: MTU negotiation failed — 23 bytes is too small for any Fluxon
        // packet (min 142 bytes). Disconnect rather than silently truncate.
        _log('ERROR: MTU negotiation failed — disconnecting: $e');
        await result.device.disconnect();
        return; // _connectingDevices removed in finally
      }

      _log('Discovering services...');
      final services = await result.device.discoverServices();
      _log('Found ${services.length} services');

      final service = services.where((s) => s.uuid == serviceUuid).firstOrNull;
      if (service == null) {
        _log('No Fluxon service — disconnecting');
        await result.device.disconnect();
        return; // _connectingDevices removed in finally
      }

      _log('Found Fluxon service');
      final char = service.characteristics
          .where((c) => c.uuid == packetCharUuid)
          .firstOrNull;
      if (char == null) {
        _log('ERROR: Characteristic not found — disconnecting');
        await result.device.disconnect();
        return; // _connectingDevices removed in finally
      }

      _log('Found characteristic, subscribing to notifications...');
      _peerCharacteristics[deviceId] = char;
      await char.setNotifyValue(true);
      char.onValueReceived.listen((data) {
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
          _deviceMtu.remove(deviceId);
          // HIGH-2: Also remove from peripheral client maps on disconnect
          _peripheralClients.remove(deviceId);
          _authenticatedPeripheralClients.remove(deviceId);
          _peripheralClientConnectedAt.remove(deviceId);
          _emitPeerUpdate();
        }
      });
    } catch (e) {
      _log('ERROR connecting: $e');
    } finally {
      // HIGH-7: Always remove from connecting set, even if connection succeeded
      // (the device has either moved to _connectedDevices or failed entirely).
      _connectingDevices.remove(deviceId);
    }
  }

  /// HIGH-2: Evict peripheral clients that haven't written in 60 seconds.
  void _evictStalePeripheralClients() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    _peripheralClients.removeWhere((deviceId, lastWrite) {
      if (lastWrite.isBefore(cutoff)) {
        _authenticatedPeripheralClients.remove(deviceId);
        _peripheralClientConnectedAt.remove(deviceId);
        _log('Evicted stale peripheral client');
        return true;
      }
      return false;
    });
  }

  /// MED-7: Disconnect peripheral clients that haven't completed a Noise
  /// handshake within 30 seconds of connecting.
  void _checkHandshakeTimeouts() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    final timedOut = <String>[];
    for (final entry in _peripheralClientConnectedAt.entries) {
      final deviceId = entry.key;
      final connectedAt = entry.value;
      if (connectedAt.isBefore(cutoff) &&
          !_authenticatedPeripheralClients.contains(deviceId)) {
        timedOut.add(deviceId);
      }
    }
    for (final deviceId in timedOut) {
      SecureLogger.warning(
        'Handshake timeout — removing unauthenticated peripheral client',
        category: 'BLE',
      );
      _peripheralClients.remove(deviceId);
      _peripheralClientConnectedAt.remove(deviceId);
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
        // CRIT-N2: If encrypt() returns null (rekey threshold reached), the session
        // was torn down. Do NOT send plaintext — skip and re-initiate the handshake.
        if (ciphertext == null) {
          _log('Session needs rekey for $peerHex — skipping send, re-initiating handshake');
          _initiateNoiseHandshake(deviceId); // HIGH-N4: Trigger re-handshake
          return false;
        }
        encodedData = ciphertext;
        _log('Encrypted packet for $peerHex');
      } else if (packet.type != MessageType.handshake) {
        // CRIT-N2: No session exists and this is not a handshake packet.
        // Drop rather than sending plaintext over BLE.
        _log('No session for $peerHex — skipping non-handshake send to prevent plaintext leak');
        return false;
      }

      // H6: Use write-with-response for reliability-critical packet types.
      final isReliable = packet.type == MessageType.handshake ||
          packet.type == MessageType.emergencyAlert;
      await char.write(encodedData, withoutResponse: !isReliable);
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
    // METADATA EXPOSURE NOTE: The encoded packet contains the source peer ID,
    // packet type, and timestamp in plaintext (only the payload is encrypted at
    // the group layer). Any BLE observer within range can observe packet type,
    // timing, and frequency of transmissions. No plaintext PII is logged here;
    // log only the byte length to avoid leaking type/timestamp to log aggregators.
    _log('Broadcasting packet, len=${data.length}');

    // Send via central connections (write to peers' characteristics) in parallel.
    // C2: Encrypt through the per-peer Noise session where available so that
    // packet headers are not observable by passive BLE sniffers.
    final centralFutures = _peerCharacteristics.entries.map((entry) async {
      try {
        var sendData = data;
        if (_noiseSessionManager.hasSession(entry.key)) {
          final encrypted = _noiseSessionManager.encrypt(data, entry.key);
          // CRIT-C2: If encrypt() returns null (rekey needed), skip this peer
          // rather than sending plaintext. HIGH-N4: Trigger re-handshake.
          if (encrypted == null) {
            _initiateNoiseHandshake(entry.key);
            return;
          }
          sendData = encrypted;
        }
        await entry.value.write(sendData, withoutResponse: true);
        _log('Sent to ${entry.key}');
      } catch (e) {
        _log('Failed to send to ${entry.key}: $e');
      }
    });

    // CRIT-1 + MED-5: Only notify authenticated peripheral clients via GATT
    // server. Send per-client encrypted data, never unencrypted plaintext.
    // If there are no authenticated peripheral clients, skip the update entirely.
    final authenticatedPeripheral = _authenticatedPeripheralClients.toList();
    final peripheralFutures = authenticatedPeripheral.map((deviceId) async {
      try {
        var sendData = data;
        if (_noiseSessionManager.hasSession(deviceId)) {
          final encrypted = _noiseSessionManager.encrypt(data, deviceId);
          if (encrypted != null) {
            sendData = encrypted;
          } else {
            // Session exists but encrypt returned null (rekey needed) — skip
            return;
          }
        } else {
          // Client in authenticated set but no session — should not happen;
          // skip rather than send plaintext.
          return;
        }
        await ble_p.BlePeripheral.updateCharacteristic(
          characteristicId: packetCharUuidStr,
          value: sendData,
        );
      } catch (e) {
        _log('Failed to update peripheral characteristic: $e');
      }
    });

    await Future.wait([...centralFutures, ...peripheralFutures]);
  }

  // ---------------------------------------------------------------------------
  // Incoming data handling (shared by both roles)
  // ---------------------------------------------------------------------------

  Future<void> _handleIncomingData(
    Uint8List data, {
    required String fromDeviceId,
  }) async {
    // H7: Reject data outside valid size range before any processing.
    if (data.isEmpty || data.length > 4096) {
      _log('Rejecting oversized data from device — dropping');
      return;
    }

    // HIGH-1: Global cross-device rate limiter using monotonic wall-clock window.
    final now = DateTime.now();
    final windowElapsed = now.difference(_globalRateWindowStart).inMilliseconds;
    if (windowElapsed >= 1000) {
      _globalPacketCount = 0;
      _globalRateWindowStart = now;
    }
    _globalPacketCount++;
    if (_globalPacketCount > _maxGlobalPacketsPerSecond) {
      _log('Global rate limit exceeded — dropping packet');
      return;
    }

    // H3: Per-device rate limiting (max 20 packets/sec).
    // Bound rate limiting to authenticated peer ID post-handshake where possible.
    final deviceRateKey = _deviceToPeerHex[fromDeviceId] ?? fromDeviceId;
    final lastTime = _lastPacketTime[deviceRateKey];
    if (lastTime != null &&
        now.difference(lastTime).inMilliseconds < _minPacketIntervalMs) {
      return; // Silently drop — don't log to avoid timing oracle
    }
    _lastPacketTime[deviceRateKey] = now;

    _lastActivityTimestamp = now;
    _log('Handling incoming data, len=${data.length}');

    // Try Noise decryption first if a session is established
    Uint8List packetData = data;
    if (_noiseSessionManager.hasSession(fromDeviceId)) {
      final decrypted = _noiseSessionManager.decrypt(data, fromDeviceId);
      if (decrypted != null) {
        packetData = decrypted;
        _log('Decrypted packet from $fromDeviceId');
      } else {
        // Decryption failed on an established Noise session — do NOT fall back
        // to plaintext. Drop the packet to prevent plaintext bypass attacks.
        SecureLogger.warning(
          'Decryption failed on established session — dropping packet',
          category: 'BLE',
        );
        return;
      }
    }

    // Try decoding with signature first; fall back only if no session exists.
    var packet = FluxonPacket.decode(packetData, hasSignature: true);

    // C4: Reject unsigned packets from peers that have completed a Noise handshake.
    if (packet == null) {
      if (_noiseSessionManager.hasSession(fromDeviceId)) {
        SecureLogger.warning(
          'Unsigned packet from authenticated peer $fromDeviceId — rejecting',
          category: 'BLE',
        );
        return;
      }
      packet = FluxonPacket.decode(packetData, hasSignature: false);
    }

    if (packet == null) {
      _log('Failed to decode packet');
      return;
    }

    // Handle Noise handshake packets specially (before signature verification,
    // since we don't yet have the remote signing key at handshake time).
    if (packet.type == MessageType.handshake) {
      await _handleHandshakePacket(fromDeviceId, packet);
      return; // Don't emit handshake packets to app layer
    }

    // CRIT-2: Validate that the packet's sourceId matches the authenticated
    // peer identity for this BLE connection. An authenticated peer cannot
    // forge packets claiming to originate from a different peer ID.
    final authenticatedPeerHex = _deviceToPeerHex[fromDeviceId];
    if (authenticatedPeerHex != null) {
      final packetSourceHex = HexUtils.encode(packet.sourceId);
      if (packetSourceHex != authenticatedPeerHex) {
        SecureLogger.warning(
          'Source ID mismatch: packet claims different origin than authenticated peer — dropping',
          category: 'BLE',
        );
        return;
      }
    }

    // C3: Verify Ed25519 signature on non-handshake packets.
    if (packet.signature != null) {
      final peerSigningKey = _noiseSessionManager.getSigningPublicKey(fromDeviceId);
      if (peerSigningKey != null) {
        final unsigned = packet.encode(); // payload without signature
        if (!Signatures.verify(unsigned, packet.signature!, peerSigningKey)) {
          SecureLogger.warning(
            'Signature verification FAILED from $fromDeviceId — dropping packet',
            category: 'BLE',
          );
          return;
        }
      }
    }

    // Check for duplicates
    if (_deduplicator.isDuplicate(packet.packetId)) {
      _log('Duplicate packet, ignoring');
      return;
    }

    _log('Valid packet received, type=${packet.type.name}');
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
          // H6: Handshakes are reliability-critical — use write-with-response.
          await char.write(responseData, withoutResponse: false);
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

      // CRIT-1: Mark this device as an authenticated peripheral client so it
      // can receive encrypted GATT notifications.
      _authenticatedPeripheralClients.add(fromDeviceId);

      // Update the peer connection with the real peer ID and signing key
      final existingConnection = _peerConnections[fromDeviceId] ??
          PeerConnection(peerId: Uint8List(32), rssi: 0);
      _peerConnections[fromDeviceId] = PeerConnection(
        peerId: remotePeerIdBytes,
        rssi: existingConnection.rssi,
        signingPublicKey: responseAndKey.remoteSigningPublicKey,
      );

      _log('Handshake complete');
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
      // H6: Handshakes are reliability-critical — use write-with-response.
      await char.write(data, withoutResponse: false);
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
