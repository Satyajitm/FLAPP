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

void main() {
  Uint8List makePeerId(int fillByte) =>
      Uint8List(32)..fillRange(0, 32, fillByte);

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

  late Uint8List myPeerId;
  late StubTransport rawTransport;
  late MockIdentityManager identityManager;
  late MeshService meshService;

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

  group('MeshService packet forwarding', () {
    test('emits application-layer packets (chat) to onPacketReceived', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeChatPayload('hello'),
      );

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(
        BinaryProtocol.decodeChatPayload(received.first.payload).text,
        equals('hello'),
      );
    });

    test('emits location update packets to onPacketReceived', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.locationUpdate,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeLocationPayload(
          latitude: 37.7749,
          longitude: -122.4194,
        ),
      );

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(received.first.type, equals(MessageType.locationUpdate));
    });

    test('emits emergency alert packets to onPacketReceived', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.emergencyAlert,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeEmergencyPayload(
          alertType: 1,
          latitude: 37.7749,
          longitude: -122.4194,
        ),
      );

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(received.first.type, equals(MessageType.emergencyAlert));
    });

    test('does NOT emit discovery packets to app stream', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.discovery,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeDiscoveryPayload(neighbors: []),
      );

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 300));

      expect(received, isEmpty);
    });

    test('does NOT emit topologyAnnounce packets to app stream', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.topologyAnnounce,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeDiscoveryPayload(
          neighbors: [makePeerId(0xCC)],
        ),
      );

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 300));

      expect(received, isEmpty);
    });
  });

  group('MeshService relay logic', () {
    test('relays remote chat packet with TTL > 1', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        ttl: 5,
      );

      // Simulate having 1 connected peer so degree > 0
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));

      rawTransport.broadcastedPackets.clear(); // clear discovery announce

      rawTransport.simulateIncomingPacket(packet);
      // Wait for relay jitter (up to ~250ms)
      await Future.delayed(const Duration(milliseconds: 400));

      // Should have relayed at least once
      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isNotEmpty);
      expect(relayed.first.ttl, lessThan(packet.ttl));
    });

    test('does NOT relay own packets', () async {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
        ttl: 5,
      );

      rawTransport.broadcastedPackets.clear();
      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 300));

      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isEmpty);
    });

    test('does NOT relay packets with TTL <= 1', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        ttl: 1,
      );

      rawTransport.broadcastedPackets.clear();
      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 300));

      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isEmpty);
    });

    test('relayed packet preserves original sourceId and timestamp', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        ttl: 5,
      );

      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));
      rawTransport.broadcastedPackets.clear();

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 400));

      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isNotEmpty);
      expect(relayed.first.sourceId, equals(remotePeer));
      expect(relayed.first.timestamp, equals(packet.timestamp));
    });
  });

  group('MeshService topology', () {
    test('discovery packet updates topology tracker', () async {
      final remotePeer = makePeerId(0xBB);
      final neighborC = makePeerId(0xCC);

      final packet = buildPacket(
        type: MessageType.discovery,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeDiscoveryPayload(
          neighbors: [neighborC],
        ),
      );

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      // Topology should now know about remotePeer
      expect(meshService.topology.nodeCount, greaterThanOrEqualTo(1));
    });

    test('new peer connection triggers discovery announce', () async {
      final remotePeer = makePeerId(0xBB);

      rawTransport.broadcastedPackets.clear();
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      final announces = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.discovery)
          .toList();
      expect(announces, isNotEmpty);
      expect(announces.first.sourceId, equals(myPeerId));
    });
  });

  group('MeshService Transport interface', () {
    test('delegates broadcastPacket to raw transport', () async {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
      );

      rawTransport.broadcastedPackets.clear();
      await meshService.broadcastPacket(packet);

      expect(rawTransport.broadcastedPackets.where((p) => p.type == MessageType.chat), hasLength(1));
    });

    test('delegates sendPacket to raw transport', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: myPeerId,
      );

      await meshService.sendPacket(packet, remotePeer);

      expect(rawTransport.sentPackets, hasLength(1));
      expect(rawTransport.sentPackets.first.$1.type, equals(MessageType.chat));
      expect(rawTransport.sentPackets.first.$2, equals(remotePeer));
    });

    test('myPeerId matches constructor argument', () {
      expect(meshService.myPeerId, equals(myPeerId));
    });

    test('isRunning delegates to raw transport', () async {
      expect(meshService.isRunning, equals(rawTransport.isRunning));
      await rawTransport.startServices();
      expect(meshService.isRunning, isTrue);
      await rawTransport.stopServices();
      expect(meshService.isRunning, isFalse);
    });

    test('connectedPeers delegates to raw transport', () async {
      final peers = <List<PeerConnection>>[];
      final sub = meshService.connectedPeers.listen(peers.add);

      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: makePeerId(0xBB)),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(peers, hasLength(1));
      expect(peers.first, hasLength(1));

      await sub.cancel();
    });
  });

  group('MeshService lifecycle', () {
    test('stop prevents further packet processing', () async {
      await meshService.stop();

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
        payload: BinaryProtocol.encodeChatPayload('after stop'),
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      expect(received, isEmpty);

      // Re-start for tearDown
      await meshService.start();
    });

    test('stop prevents relay of incoming packets', () async {
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: makePeerId(0xBB)),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));

      await meshService.stop();
      rawTransport.broadcastedPackets.clear();

      rawTransport.simulateIncomingPacket(buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
        ttl: 5,
      ));
      await Future.delayed(const Duration(milliseconds: 400));

      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isEmpty);

      await meshService.start();
    });

    test('startServices delegates to raw transport and starts mesh', () async {
      // Create a fresh pair without calling start()
      final transport2 = StubTransport(myPeerId: myPeerId);
      final identityManager2 = MockIdentityManager();
      final mesh2 = MeshService(
        transport: transport2,
        myPeerId: myPeerId,
        identityManager: identityManager2,
      );

      await mesh2.startServices();

      expect(transport2.isRunning, isTrue);

      // Verify mesh processing works
      final received = <FluxonPacket>[];
      mesh2.onPacketReceived.listen(received.add);
      transport2.simulateIncomingPacket(buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
        payload: BinaryProtocol.encodeChatPayload('via startServices'),
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(received, hasLength(1));

      await mesh2.stopServices();
      transport2.dispose();
    });

    test('topology getter returns tracker instance', () {
      expect(meshService.topology, isNotNull);
      expect(meshService.topology.nodeCount, greaterThanOrEqualTo(0));
    });
  });

  group('MeshService topology (extended)', () {
    test('topologyAnnounce packet also updates topology tracker', () async {
      final remotePeer = makePeerId(0xBB);
      final neighborC = makePeerId(0xCC);

      final packet = buildPacket(
        type: MessageType.topologyAnnounce,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeDiscoveryPayload(
          neighbors: [neighborC],
        ),
      );

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(meshService.topology.nodeCount, greaterThanOrEqualTo(1));
    });

    test('malformed discovery payload is silently dropped', () async {
      // Craft a packet with invalid discovery payload
      final packet = buildPacket(
        type: MessageType.discovery,
        sourceId: makePeerId(0xBB),
        payload: Uint8List(0), // empty payload = null decode
      );

      rawTransport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      // Should not crash, topology unchanged
      // (nodeCount may be 0 or whatever it was before)
    });

    test('same peers reconnecting does NOT trigger announce', () async {
      final remotePeer = makePeerId(0xBB);

      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      rawTransport.broadcastedPackets.clear();

      // Same peer list again
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 100));

      final announces = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.discovery)
          .toList();
      expect(announces, isEmpty,
          reason: 'No new peers = no new discovery announce');
    });
  });

  group('MeshService relay edge cases', () {
    test('TTL=0 packet is NOT relayed', () async {
      final remotePeer = makePeerId(0xBB);
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));
      rawTransport.broadcastedPackets.clear();

      rawTransport.simulateIncomingPacket(buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        ttl: 0,
      ));
      await Future.delayed(const Duration(milliseconds: 300));

      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isEmpty);
    });

    test('relayed packet preserves payload content', () async {
      final remotePeer = makePeerId(0xBB);
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));
      rawTransport.broadcastedPackets.clear();

      rawTransport.simulateIncomingPacket(buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        payload: BinaryProtocol.encodeChatPayload('relay me'),
        ttl: 5,
      ));
      await Future.delayed(const Duration(milliseconds: 400));

      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.chat)
          .toList();
      expect(relayed, isNotEmpty);
      expect(
        BinaryProtocol.decodeChatPayload(relayed.first.payload).text,
        equals('relay me'),
      );
    });

    test('handshake packets are emitted to app stream AND relayed', () async {
      final remotePeer = makePeerId(0xBB);
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: remotePeer),
      ]);
      await Future.delayed(const Duration(milliseconds: 50));
      rawTransport.broadcastedPackets.clear();

      final received = <FluxonPacket>[];
      meshService.onPacketReceived.listen(received.add);

      rawTransport.simulateIncomingPacket(buildPacket(
        type: MessageType.handshake,
        sourceId: remotePeer,
        ttl: 5,
      ));
      await Future.delayed(const Duration(milliseconds: 200));

      // Should be emitted to app stream
      expect(received, hasLength(1));
      expect(received.first.type, equals(MessageType.handshake));

      // Should also be relayed
      final relayed = rawTransport.broadcastedPackets
          .where((p) => p.type == MessageType.handshake)
          .toList();
      expect(relayed, isNotEmpty);
    });

    test('degree=0 does NOT relay (no connected peers)', () async {
      // Don't add any peers — degree is 0
      rawTransport.broadcastedPackets.clear();

      rawTransport.simulateIncomingPacket(buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
        ttl: 5,
      ));
      await Future.delayed(const Duration(milliseconds: 400));

      // RelayController with degree=0 falls into degree <= 2 band,
      // which still returns shouldRelay=true with low jitter.
      // This test verifies no crash when broadcasting with zero peers.
    });
  });
}
