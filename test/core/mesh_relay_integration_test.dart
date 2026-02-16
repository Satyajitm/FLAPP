import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/identity_manager.dart';
import 'package:fluxon_app/core/mesh/mesh_service.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:mocktail/mocktail.dart';

// Mock IdentityManager for testing
class MockIdentityManager extends Mock implements IdentityManager {
  final Uint8List _signingPrivateKey = Uint8List.fromList(
    List.generate(64, (i) => i & 0xFF),
  );
  final Uint8List _signingPublicKey = Uint8List.fromList(
    List.generate(32, (i) => i & 0xFF),
  );

  @override
  Uint8List get signingPrivateKey => _signingPrivateKey;

  @override
  Uint8List get signingPublicKey => _signingPublicKey;
}

/// Simulates a 3-phone linear topology: A — B — C
///
/// A and C cannot reach each other directly. B relays messages between them.
/// Uses StubTransport + MeshService to test the full relay chain in-process.
void main() {
  Uint8List makePeerId(int fillByte) =>
      Uint8List(32)..fillRange(0, 32, fillByte);

  late Uint8List peerIdA, peerIdB, peerIdC;
  late StubTransport transportA, transportB, transportC;
  late MockIdentityManager identityManagerA, identityManagerB, identityManagerC;
  late MeshService meshA, meshB, meshC;

  setUp(() async {
    peerIdA = makePeerId(0xAA);
    peerIdB = makePeerId(0xBB);
    peerIdC = makePeerId(0xCC);

    transportA = StubTransport(myPeerId: peerIdA);
    transportB = StubTransport(myPeerId: peerIdB);
    transportC = StubTransport(myPeerId: peerIdC);

    identityManagerA = MockIdentityManager();
    identityManagerB = MockIdentityManager();
    identityManagerC = MockIdentityManager();

    meshA = MeshService(
      transport: transportA,
      myPeerId: peerIdA,
      identityManager: identityManagerA,
    );
    meshB = MeshService(
      transport: transportB,
      myPeerId: peerIdB,
      identityManager: identityManagerB,
    );
    meshC = MeshService(
      transport: transportC,
      myPeerId: peerIdC,
      identityManager: identityManagerC,
    );

    await meshA.start();
    await meshB.start();
    await meshC.start();

    // Set up linear topology: A—B—C
    // A sees only B
    transportA.simulatePeersChanged([
      PeerConnection(peerId: peerIdB),
    ]);
    // B sees A and C
    transportB.simulatePeersChanged([
      PeerConnection(peerId: peerIdA),
      PeerConnection(peerId: peerIdC),
    ]);
    // C sees only B
    transportC.simulatePeersChanged([
      PeerConnection(peerId: peerIdB),
    ]);

    // Allow peer change handlers to fire
    await Future.delayed(const Duration(milliseconds: 100));

    // Clear any discovery announce packets from setup
    transportA.broadcastedPackets.clear();
    transportB.broadcastedPackets.clear();
    transportC.broadcastedPackets.clear();
  });

  tearDown(() async {
    await meshA.stop();
    await meshB.stop();
    await meshC.stop();
    transportA.dispose();
    transportB.dispose();
    transportC.dispose();
  });

  group('3-phone relay: A — B — C', () {
    test('A sends chat, B relays, C receives via B', () async {
      // Listen for packets on C's mesh service (app-layer stream)
      final cReceived = <FluxonPacket>[];
      meshC.onPacketReceived.listen(cReceived.add);

      // A broadcasts a chat packet with TTL=5
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: peerIdA,
        payload: BinaryProtocol.encodeChatPayload('hello from A'),
        ttl: 5,
      );

      // Step 1: A's packet reaches B (simulating BLE delivery A→B)
      transportB.simulateIncomingPacket(chatPacket);

      // Wait for B's relay jitter (RelayController adds up to ~220ms)
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 2: B should have relayed the packet
      final relayedByB = transportB.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayedByB, isNotEmpty, reason: 'B should relay the chat packet');

      final relayedPacket = relayedByB.first;
      expect(relayedPacket.ttl, lessThan(chatPacket.ttl),
          reason: 'Relayed TTL should be decremented');
      expect(relayedPacket.sourceId, equals(peerIdA),
          reason: 'Source ID should be preserved (still A)');
      expect(relayedPacket.timestamp, equals(chatPacket.timestamp),
          reason: 'Timestamp should be preserved');

      // Step 3: Deliver B's relayed packet to C (simulating BLE delivery B→C)
      transportC.simulateIncomingPacket(relayedPacket);

      await Future.delayed(const Duration(milliseconds: 100));

      // Step 4: C should have received the original chat message
      expect(cReceived, hasLength(1),
          reason: 'C should receive exactly one chat message');
      expect(
        BinaryProtocol.decodeChatPayload(cReceived.first.payload),
        equals('hello from A'),
      );
      expect(cReceived.first.sourceId, equals(peerIdA),
          reason: 'C sees the message as coming from A');
    });

    test('emergency alert relays with minimal delay', () async {
      final cReceived = <FluxonPacket>[];
      meshC.onPacketReceived.listen(cReceived.add);

      final sosPacket = BinaryProtocol.buildPacket(
        type: MessageType.emergencyAlert,
        sourceId: peerIdA,
        payload: BinaryProtocol.encodeEmergencyPayload(
          alertType: 1,
          latitude: 37.7749,
          longitude: -122.4194,
          message: 'Help!',
        ),
        ttl: 7,
      );

      // A→B
      transportB.simulateIncomingPacket(sosPacket);
      await Future.delayed(const Duration(milliseconds: 200));

      final relayedByB = transportB.broadcastedPackets
          .where((p) => p.type == MessageType.emergencyAlert)
          .toList();
      expect(relayedByB, isNotEmpty);

      // B→C
      transportC.simulateIncomingPacket(relayedByB.first);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(cReceived, hasLength(1));
      final decoded =
          BinaryProtocol.decodeEmergencyPayload(cReceived.first.payload);
      expect(decoded, isNotNull);
      expect(decoded!.message, equals('Help!'));
    });

    test('TTL=1 packet does NOT get relayed', () async {
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: peerIdA,
        payload: BinaryProtocol.encodeChatPayload('short range'),
        ttl: 1,
      );

      transportB.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 300));

      // B should NOT relay (TTL too low)
      final relayedByB = transportB.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayedByB, isEmpty,
          reason: 'TTL=1 packet should not be relayed');
    });

    test('multi-hop: TTL decrements at each hop', () async {
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: peerIdA,
        payload: BinaryProtocol.encodeChatPayload('multi-hop'),
        ttl: 5,
      );

      // A→B
      transportB.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 500));

      final relayedByB = transportB.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayedByB, isNotEmpty);

      // TTL should have decremented by at least 1
      final ttlAfterB = relayedByB.first.ttl;
      expect(ttlAfterB, lessThan(5));

      // B→C: C also relays (it has peers)
      transportC.simulateIncomingPacket(relayedByB.first);
      await Future.delayed(const Duration(milliseconds: 500));

      final relayedByC = transportC.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();

      if (ttlAfterB > 1) {
        // C should relay if TTL still > 1
        expect(relayedByC, isNotEmpty);
        expect(relayedByC.first.ttl, lessThan(ttlAfterB));
      }
    });
  });
}
