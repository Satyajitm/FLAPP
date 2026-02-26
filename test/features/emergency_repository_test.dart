import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/group_cipher.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/group_storage.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:fluxon_app/core/transport/transport_config.dart';
import 'package:fluxon_app/features/emergency/data/mesh_emergency_repository.dart';
import 'package:fluxon_app/features/emergency/emergency_controller.dart';

// ---------------------------------------------------------------------------
// Mock Transport
// ---------------------------------------------------------------------------

class MockTransport implements Transport {
  final StreamController<FluxonPacket> _packetController =
      StreamController<FluxonPacket>.broadcast();
  final List<FluxonPacket> broadcastedPackets = [];

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    broadcastedPackets.add(packet);
  }

  void simulateIncomingPacket(FluxonPacket packet) {
    _packetController.add(packet);
  }

  void dispose() {
    _packetController.close();
  }

  @override
  Stream<List<PeerConnection>> get connectedPeers => const Stream.empty();
  @override
  bool get isRunning => true;
  @override
  Uint8List get myPeerId => Uint8List(32);
  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async => true;
  @override
  Future<void> startServices() async {}
  @override
  Future<void> stopServices() async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

FluxonPacket _buildEmergencyPacket({
  int senderByte = 0xAA,
  int alertType = 0,
  double lat = 37.7749,
  double lon = -122.4194,
  String message = 'Help!',
}) {
  return BinaryProtocol.buildPacket(
    type: MessageType.emergencyAlert,
    sourceId: Uint8List(32)..fillRange(0, 32, senderByte),
    payload: BinaryProtocol.encodeEmergencyPayload(
      alertType: alertType,
      latitude: lat,
      longitude: lon,
      message: message,
    ),
    ttl: FluxonPacket.maxTTL,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MeshEmergencyRepository', () {
    late MockTransport transport;
    late MeshEmergencyRepository repository;
    final myPeerId = _makePeerId(0xCC);

    setUp(() {
      transport = MockTransport();
      repository = MeshEmergencyRepository(
        transport: transport,
        myPeerId: myPeerId,
        config: const TransportConfig(emergencyRebroadcastCount: 2),
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('onAlertReceived emits decoded alert for incoming emergency packets',
        () async {
      final packet = _buildEmergencyPacket(
        senderByte: 0xBB,
        alertType: EmergencyAlertType.sos.value,
        lat: 40.0,
        lon: -74.0,
        message: 'SOS!',
      );

      final future = repository.onAlertReceived.first;
      transport.simulateIncomingPacket(packet);

      final alert = await future;
      expect(alert.sender, equals(_makePeerId(0xBB)));
      expect(alert.type, equals(EmergencyAlertType.sos));
      expect(alert.latitude, closeTo(40.0, 0.001));
      expect(alert.longitude, closeTo(-74.0, 0.001));
      expect(alert.message, equals('SOS!'));
    });

    test('onAlertReceived ignores non-emergency packets', () async {
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: Uint8List(32),
        payload: BinaryProtocol.encodeChatPayload('hello'),
      );

      final completer = Completer<EmergencyAlert>();
      final sub = repository.onAlertReceived.listen(completer.complete);

      transport.simulateIncomingPacket(chatPacket);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, isFalse);

      await sub.cancel();
    });

    test('sendAlert broadcasts N times per config', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.medical,
        latitude: 34.0,
        longitude: -118.0,
        message: 'Need help',
      );

      // Config says emergencyRebroadcastCount = 2
      expect(transport.broadcastedPackets, hasLength(2));

      // All packets should be emergency type with max TTL
      for (final pkt in transport.broadcastedPackets) {
        expect(pkt.type, equals(MessageType.emergencyAlert));
        expect(pkt.ttl, equals(FluxonPacket.maxTTL));
      }
    });

    test('sendAlert encodes payload correctly', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.danger,
        latitude: 51.5,
        longitude: -0.12,
        message: 'Danger zone',
      );

      final pkt = transport.broadcastedPackets.first;
      final decoded = BinaryProtocol.decodeEmergencyPayload(pkt.payload);
      expect(decoded, isNotNull);
      expect(decoded!.alertType, equals(EmergencyAlertType.danger.value));
      expect(decoded.latitude, closeTo(51.5, 0.001));
      expect(decoded.longitude, closeTo(-0.12, 0.001));
      expect(decoded.message, equals('Danger zone'));
    });

    test('sendAlert sets sourceId to myPeerId', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.sos,
        latitude: 0,
        longitude: 0,
      );

      final pkt = transport.broadcastedPackets.first;
      expect(PeerId(pkt.sourceId), equals(myPeerId));
    });

    test('multiple incoming alerts arrive in order', () async {
      final alerts = <EmergencyAlert>[];
      final sub = repository.onAlertReceived.listen(alerts.add);

      transport.simulateIncomingPacket(
        _buildEmergencyPacket(senderByte: 0x01, message: 'first'),
      );
      transport.simulateIncomingPacket(
        _buildEmergencyPacket(senderByte: 0x02, message: 'second'),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(alerts, hasLength(2));
      expect(alerts[0].message, equals('first'));
      expect(alerts[1].message, equals('second'));

      await sub.cancel();
    });
  });

  // -------------------------------------------------------------------------
  // Group encryption tests
  // -------------------------------------------------------------------------

  group('MeshEmergencyRepository — group encryption', () {
    late MockTransport transport;
    late GroupManager groupManager;
    late MeshEmergencyRepository repository;
    final myPeerId = _makePeerId(0xCC);

    setUp(() async {
      transport = MockTransport();
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      await groupManager.createGroup('sos-pass', groupName: 'SOS Team');
      repository = MeshEmergencyRepository(
        transport: transport,
        myPeerId: myPeerId,
        config: const TransportConfig(emergencyRebroadcastCount: 1),
        groupManager: groupManager,
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('sendAlert encrypts payload when in a group', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.sos,
        latitude: 37.0,
        longitude: -122.0,
        message: 'encrypted SOS',
      );

      expect(transport.broadcastedPackets, hasLength(1));
      final pkt = transport.broadcastedPackets.first;

      // Payload is encrypted — raw decode should fail or give wrong data
      final decoded = BinaryProtocol.decodeEmergencyPayload(pkt.payload);
      // With XOR encryption the binary structure is scrambled
      if (decoded != null) {
        expect(decoded.message, isNot(equals('encrypted SOS')));
      }
    });

    test('incoming encrypted alert is decrypted correctly', () async {
      // Build an encrypted emergency packet
      final plainPayload = BinaryProtocol.encodeEmergencyPayload(
        alertType: EmergencyAlertType.medical.value,
        latitude: 40.0,
        longitude: -74.0,
        message: 'Need medic!',
      );
      final encrypted = groupManager.encryptForGroup(plainPayload)!;
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.emergencyAlert,
        sourceId: _makePeerId(0xDD).bytes,
        payload: encrypted,
        ttl: FluxonPacket.maxTTL,
      );

      final future = repository.onAlertReceived.first;
      transport.simulateIncomingPacket(packet);

      final alert = await future;
      expect(alert.type, equals(EmergencyAlertType.medical));
      expect(alert.latitude, closeTo(40.0, 0.001));
      expect(alert.longitude, closeTo(-74.0, 0.001));
      expect(alert.message, equals('Need medic!'));
    });

    test('sendAlert sets sourceId to myPeerId when in a group', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.danger,
        latitude: 0,
        longitude: 0,
      );

      final pkt = transport.broadcastedPackets.first;
      expect(PeerId(pkt.sourceId), equals(myPeerId));
    });
  });

  group('MeshEmergencyRepository — no group (encryption bypassed)', () {
    late MockTransport transport;
    late GroupManager groupManager;
    late MeshEmergencyRepository repository;
    final myPeerId = _makePeerId(0xCC);

    setUp(() {
      transport = MockTransport();
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      // NOT in a group
      repository = MeshEmergencyRepository(
        transport: transport,
        myPeerId: myPeerId,
        config: const TransportConfig(emergencyRebroadcastCount: 1),
        groupManager: groupManager,
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('sendAlert sends plaintext when not in a group', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.sos,
        latitude: 51.5,
        longitude: -0.1,
        message: 'plain SOS',
      );

      final pkt = transport.broadcastedPackets.first;
      final decoded = BinaryProtocol.decodeEmergencyPayload(pkt.payload);
      expect(decoded, isNotNull);
      expect(decoded!.message, equals('plain SOS'));
    });

    test('incoming plaintext alert is received without decryption', () async {
      final packet = _buildEmergencyPacket(
        senderByte: 0xDD,
        message: 'plain alert',
      );

      final future = repository.onAlertReceived.first;
      transport.simulateIncomingPacket(packet);

      final alert = await future;
      expect(alert.message, equals('plain alert'));
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles for group encryption
// ---------------------------------------------------------------------------

class _FakeGroupCipher implements GroupCipher {
  @override
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey, {Uint8List? additionalData}) {
    if (groupKey == null) return null;
    final result = Uint8List(plaintext.length);
    for (var i = 0; i < plaintext.length; i++) {
      result[i] = plaintext[i] ^ groupKey[i % groupKey.length];
    }
    return result;
  }

  @override
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey, {Uint8List? additionalData}) {
    return encrypt(data, groupKey);
  }

  @override
  Uint8List deriveGroupKey(String passphrase, Uint8List salt) {
    final key = Uint8List(32);
    final bytes = passphrase.codeUnits;
    for (var i = 0; i < 32; i++) {
      key[i] = bytes[i % bytes.length] ^ (i * 7);
    }
    return key;
  }

  @override
  String generateGroupId(String passphrase, Uint8List salt) =>
      'fake-group-${passphrase.hashCode.toRadixString(16)}';

  @override
  Uint8List generateSalt() => Uint8List(16); // Fixed salt for deterministic tests

  static const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  @override
  String encodeSalt(Uint8List salt) {
    var buffer = 0;
    var bitsLeft = 0;
    final result = StringBuffer();
    for (final byte in salt) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        result.writeCharCode(_b32.codeUnitAt((buffer >> bitsLeft) & 0x1F));
      }
    }
    if (bitsLeft > 0) {
      result.writeCharCode(_b32.codeUnitAt((buffer << (5 - bitsLeft)) & 0x1F));
    }
    return result.toString();
  }

  @override
  Uint8List decodeSalt(String code) {
    final upper = code.toUpperCase();
    var buffer = 0;
    var bitsLeft = 0;
    final result = <int>[];
    for (final ch in upper.split('')) {
      final val = _b32.indexOf(ch);
      if (val < 0) throw FormatException('Invalid base32 char: $ch');
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        result.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(result);
  }

  @override
  void clearCache() {}

  @override
  Future<DerivedGroup> deriveAsync(String passphrase, Uint8List salt) async =>
      DerivedGroup(deriveGroupKey(passphrase, salt), generateGroupId(passphrase, salt));
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _store[key] = value;
    } else {
      _store.remove(key);
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _store[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
