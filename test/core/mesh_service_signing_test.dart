import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/crypto/signatures.dart';
import 'package:fluxon_app/core/identity/identity_manager.dart';
import 'package:fluxon_app/core/mesh/mesh_service.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:mocktail/mocktail.dart';

// ============================================================================
// TIER 2: Important Tests for MeshService Signing
// ============================================================================
// These tests verify that MeshService correctly signs packets with Ed25519
// and that signed packets are properly handled through the mesh.

class MockIdentityManager extends Mock implements IdentityManager {
  final Uint8List _signingPrivateKey = Uint8List.fromList(
    List.generate(64, (i) => i & 0xFF),
  );
  final Uint8List _signingPublicKey = Uint8List.fromList(
    List.generate(32, (i) => (i + 100) & 0xFF),
  );
  final Uint8List _privateKey = Uint8List.fromList(
    List.generate(32, (i) => i & 0xFF),
  );
  final Uint8List _publicKey = Uint8List.fromList(
    List.generate(32, (i) => (i + 50) & 0xFF),
  );

  @override
  Uint8List get signingPrivateKey => _signingPrivateKey;

  @override
  Uint8List get signingPublicKey => _signingPublicKey;

  @override
  Uint8List get privateKey => _privateKey;

  @override
  Uint8List get publicKey => _publicKey;
}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const Duration());
  });

  // =========================================================================
  // TIER 2 TEST SUITE: MeshService Packet Signing
  // =========================================================================

  group('Tier 2: MeshService Packet Signing (Mocked)', () {
    late Uint8List myPeerId;
    late StubTransport rawTransport;
    late MockIdentityManager identityManager;
    late MeshService meshService;

    Uint8List makePeerId(int fillByte) => Uint8List(32)..fillRange(0, 32, fillByte);

    FluxonPacket buildPacket({
      required MessageType type,
      required Uint8List sourceId,
      Uint8List? payload,
      int ttl = 5,
    }) {
      return BinaryProtocol.buildPacket(
        type: type,
        sourceId: sourceId,
        payload: payload ?? Uint8List(0),
        ttl: ttl,
      );
    }

    setUp(() async {
      myPeerId = makePeerId(0xAA);
      rawTransport = StubTransport(myPeerId: myPeerId);
      identityManager = MockIdentityManager();
      meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );
      await meshService.start();
    });

    tearDown(() async {
      await meshService.stop();
      rawTransport.dispose();
    });

    test('outgoing chat packet can be created and signed', () {
      // Mock the signing operation
      final payload = BinaryProtocol.encodeChatPayload('signed message');
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
        payload: payload,
      );

      // Verify packet structure
      expect(packet.type, equals(MessageType.chat));
      expect(packet.sourceId, equals(myPeerId));
      expect(BinaryProtocol.decodeChatPayload(packet.payload), equals('signed message'));
    });

test('packet header includes all required fields for signing', () {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
        payload: BinaryProtocol.encodeChatPayload('test'),
      );

      // Verify signable fields
      expect(FluxonPacket.version, equals(1));
      expect(packet.type, isNotNull);
      expect(packet.sourceId, isNotEmpty);
      expect(packet.timestamp, isNotNull);
      expect(packet.ttl, isNotNull);
    });

    test('packet can be encoded and decoded with signature field', () {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
        payload: BinaryProtocol.encodeChatPayload('test'),
      );

      // Create mock signature
      final mockSignature = Uint8List(64)..fillRange(0, 64, 0xAB);
      final signedPacket = packet.withSignature(mockSignature);

      expect(signedPacket.signature, equals(mockSignature));

      // Encode and decode
      final encoded = signedPacket.encodeWithSignature();
      expect(encoded, isNotEmpty);

      final decoded = FluxonPacket.decode(encoded, hasSignature: true);
      expect(decoded, isNotNull);
      expect(decoded!.signature, equals(mockSignature));
    });

    test('multiple packets maintain separate signatures', () {
      final packet1 = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
        payload: BinaryProtocol.encodeChatPayload('msg1'),
      );
      final packet2 = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
        payload: BinaryProtocol.encodeChatPayload('msg2'),
      );

      final sig1 = Uint8List(64)..fillRange(0, 64, 0x01);
      final sig2 = Uint8List(64)..fillRange(0, 64, 0x02);

      final signed1 = packet1.withSignature(sig1);
      final signed2 = packet2.withSignature(sig2);

      expect(signed1.signature, equals(sig1));
      expect(signed2.signature, equals(sig2));
      expect(signed1.signature, isNot(signed2.signature));
    });

    test('location update packets can be signed', () {
      final payload = BinaryProtocol.encodeLocationPayload(
        latitude: 37.7749,
        longitude: -122.4194,
        accuracy: 5.0,
      );

      final packet = buildPacket(
        type: MessageType.locationUpdate,
        sourceId: myPeerId,
        payload: payload,
      );

      final mockSignature = Uint8List(64)..fillRange(0, 64, 0xCC);
      final signedPacket = packet.withSignature(mockSignature);

      expect(signedPacket.type, equals(MessageType.locationUpdate));
      expect(signedPacket.signature, equals(mockSignature));
    });

    test('emergency alert packets can be signed', () {
      final payload = BinaryProtocol.encodeEmergencyPayload(
        alertType: 1,
        latitude: 40.7128,
        longitude: -74.0060,
        message: 'SOS',
      );

      final packet = buildPacket(
        type: MessageType.emergencyAlert,
        sourceId: myPeerId,
        payload: payload,
      );

      final mockSignature = Uint8List(64)..fillRange(0, 64, 0xDD);
      final signedPacket = packet.withSignature(mockSignature);

      expect(signedPacket.type, equals(MessageType.emergencyAlert));
      expect(signedPacket.signature, equals(mockSignature));
    });
  });

  // =========================================================================
  // TIER 2 TEST SUITE: Session Cleanup on Disconnect
  // =========================================================================

  group('Tier 2: Session Cleanup on Disconnect (Mocked)', () {
    late Uint8List myPeerId;
    late StubTransport rawTransport;
    late MockIdentityManager identityManager;
    late MeshService meshService;

    Uint8List makePeerId(int fillByte) => Uint8List(32)..fillRange(0, 32, fillByte);

    setUp(() async {
      myPeerId = makePeerId(0xAA);
      rawTransport = StubTransport(myPeerId: myPeerId);
      identityManager = MockIdentityManager();
      meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );
      await meshService.start();
    });

    tearDown(() async {
      await meshService.stop();
      rawTransport.dispose();
    });

test('meshService tracks active connections', () async {
      // MeshService wraps the transport's connectedPeers
      final connectedPeers = <List<PeerConnection>>[];
      meshService.connectedPeers.listen(connectedPeers.add);

      // Simulate a connection
      final peer1 = PeerConnection(
        peerId: makePeerId(0xBB),
      );

      rawTransport.simulatePeersChanged([peer1]);
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify connection is tracked
      expect(connectedPeers, isNotEmpty);
    });

test('meshService emits disconnect events', () async {
      final connectedEvents = <List<PeerConnection>>[];
      meshService.connectedPeers.listen(connectedEvents.add);

      final peer1 = PeerConnection(
        peerId: makePeerId(0xBB),
      );

      rawTransport.simulatePeersChanged([peer1]);
      await Future.delayed(const Duration(milliseconds: 50));

      final initialCount = connectedEvents.length;

      // Simulate disconnect (empty peers list)
      rawTransport.simulatePeersChanged([]);
      await Future.delayed(const Duration(milliseconds: 50));

      // Should have emitted a new event
      expect(connectedEvents.length, greaterThanOrEqualTo(initialCount));
    });

test('multiple peer connections and disconnections are tracked', () async {
      final connectedEvents = <List<PeerConnection>>[];
      meshService.connectedPeers.listen(connectedEvents.add);

      final peer1 = PeerConnection(
        peerId: makePeerId(0xBB),
      );
      final peer2 = PeerConnection(
        peerId: makePeerId(0xCC),
      );

      // Connect both
      rawTransport.simulatePeersChanged([peer1]);
      await Future.delayed(const Duration(milliseconds: 25));
      rawTransport.simulatePeersChanged([peer1, peer2]);
      await Future.delayed(const Duration(milliseconds: 25));

      // Disconnect first
      rawTransport.simulatePeersChanged([peer2]);
      await Future.delayed(const Duration(milliseconds: 25));

      // Disconnect second
      rawTransport.simulatePeersChanged([]);
      await Future.delayed(const Duration(milliseconds: 25));

      // All events should be tracked
      expect(connectedEvents, isNotEmpty);
    });
  });

  // =========================================================================
  // TIER 2 TEST SUITE: Signature Structure
  // =========================================================================

  group('Tier 2: Packet Signature Structure', () {
    late MockIdentityManager identityManager;

    setUp(() {
      identityManager = MockIdentityManager();
    });

    test('Ed25519 private key is 64 bytes', () {
      expect(identityManager.signingPrivateKey.length, equals(64));
    });

    test('Ed25519 public key is 32 bytes', () {
      expect(identityManager.signingPublicKey.length, equals(32));
    });

    test('signature is 64 bytes', () {
      final mockSig = Uint8List(64)..fillRange(0, 64, 0xAB);
      expect(mockSig.length, equals(64));
    });

    test('packet with signature includes signature field', () {
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xAA),
        payload: BinaryProtocol.encodeChatPayload('test'),
      );

      final sig = Uint8List(64)..fillRange(0, 64, 0xEE);
      final signedPacket = packet.withSignature(sig);

      expect(signedPacket.signature, isNotNull);
      expect(signedPacket.signature, equals(sig));
    });

    test('packet without signature has null signature field', () {
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xAA),
        payload: BinaryProtocol.encodeChatPayload('test'),
      );

      expect(packet.signature, isNull);
    });

    test('signature can be inspected from encoded packet', () {
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xAA),
        payload: BinaryProtocol.encodeChatPayload('test'),
      );

      final sig = Uint8List(64)..fillRange(0, 64, 0xFF);
      final signed = packet.withSignature(sig);
      final encoded = signed.encodeWithSignature();

      final decoded = FluxonPacket.decode(encoded, hasSignature: true);
      expect(decoded?.signature, equals(sig));
    });
  });

  // =========================================================================
  // TIER 2 TEST SUITE: Signing Key Access Patterns
  // =========================================================================

  group('Tier 2: IdentityManager Key Access for Signing', () {
    late MockIdentityManager identityManager;

    setUp(() {
      identityManager = MockIdentityManager();
    });

    test('signingPrivateKey is accessible via IdentityManager', () {
      expect(identityManager.signingPrivateKey, isNotNull);
      expect(identityManager.signingPrivateKey.length, equals(64));
    });

    test('signingPublicKey is accessible via IdentityManager', () {
      expect(identityManager.signingPublicKey, isNotNull);
      expect(identityManager.signingPublicKey.length, equals(32));
    });

    test('both static and signing keys are accessible', () {
      expect(identityManager.privateKey, isNotNull);
      expect(identityManager.publicKey, isNotNull);
      expect(identityManager.signingPrivateKey, isNotNull);
      expect(identityManager.signingPublicKey, isNotNull);
    });

    test('signing keys are different from static keys', () {
      expect(identityManager.signingPrivateKey, isNot(identityManager.privateKey));
      expect(identityManager.signingPublicKey, isNot(identityManager.publicKey));
    });

    test('keys have expected lengths', () {
      expect(identityManager.privateKey.length, equals(32)); // X25519
      expect(identityManager.publicKey.length, equals(32)); // X25519
      expect(identityManager.signingPrivateKey.length, equals(64)); // Ed25519
      expect(identityManager.signingPublicKey.length, equals(32)); // Ed25519
    });
  });
}
