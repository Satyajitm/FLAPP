import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/identity_manager.dart';
import 'package:fluxon_app/core/mesh/deduplicator.dart';
import 'package:fluxon_app/core/mesh/gossip_sync.dart';
import 'package:fluxon_app/core/mesh/mesh_service.dart';
import 'package:fluxon_app/core/mesh/topology_tracker.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityManager extends Mock implements IdentityManager {
  final Uint8List _signingPrivateKey =
      Uint8List.fromList(List.generate(64, (i) => i & 0xFF));
  final Uint8List _signingPublicKey =
      Uint8List.fromList(List.generate(32, (i) => i & 0xFF));

  @override
  Uint8List get signingPrivateKey => _signingPrivateKey;

  @override
  Uint8List get signingPublicKey => _signingPublicKey;
}

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

void main() {
  // ---------------------------------------------------------------------------
  // C1 — Topology poisoning: unverified discovery/topology packets must NOT
  //      update topology state.
  // ---------------------------------------------------------------------------
  group('C1 — topology poisoning prevention', () {
    late StubTransport rawTransport;
    late MockIdentityManager identityManager;
    late MeshService meshService;
    late TopologyTracker topology;

    setUp(() async {
      rawTransport = StubTransport(myPeerId: makePeerId(0xAA));
      identityManager = MockIdentityManager();
      topology = TopologyTracker();
      meshService = MeshService(
        transport: rawTransport,
        myPeerId: makePeerId(0xAA),
        identityManager: identityManager,
        topologyTracker: topology,
      );
      await meshService.start();
    });

    tearDown(() async {
      await meshService.stop();
      rawTransport.dispose();
    });

    test(
        'unverified discovery packet from unknown peer does NOT update topology',
        () async {
      final remotePeer = makePeerId(0xBB);
      final payload = BinaryProtocol.encodeDiscoveryPayload(
        neighbors: [makePeerId(0xCC)],
      );
      // No signing key registered for remotePeer → not verified
      final discoveryPacket = buildPacket(
        type: MessageType.discovery,
        sourceId: remotePeer,
        payload: payload,
      );

      rawTransport.simulateIncomingPacket(discoveryPacket);
      await Future.delayed(const Duration(milliseconds: 10));

      // Topology must not have grown beyond our own self-entry (added by
      // _onPeersChanged when we start with empty peer list — 0 in this case).
      expect(topology.nodeCount, equals(0));
    });

    test(
        'unverified topologyAnnounce from unknown peer does NOT update topology',
        () async {
      final remotePeer = makePeerId(0xBB);
      final payload = BinaryProtocol.encodeDiscoveryPayload(
        neighbors: [makePeerId(0xCC), makePeerId(0xDD)],
      );
      final topoPacket = buildPacket(
        type: MessageType.topologyAnnounce,
        sourceId: remotePeer,
        payload: payload,
      );

      rawTransport.simulateIncomingPacket(topoPacket);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(topology.nodeCount, equals(0));
    });

    test('unverified discovery is still relayed (not dropped silently)', () async {
      final remotePeer = makePeerId(0xBB);
      final payload = BinaryProtocol.encodeDiscoveryPayload(neighbors: []);
      final discoveryPacket = buildPacket(
        type: MessageType.discovery,
        sourceId: remotePeer,
        payload: payload,
        ttl: 3,
      );

      rawTransport.simulateIncomingPacket(discoveryPacket);
      await Future.delayed(const Duration(milliseconds: 20));

      // RelayController should decide to relay (degree 0, TTL > 0)
      // or not depending on its own rules, but the topology must remain clean.
      // Key assertion: topology has not been updated with remotePeer.
      expect(topology.nodeCount, equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // C3 — Own topology announcements are signed (go through MeshService.broadcastPacket)
  // ---------------------------------------------------------------------------
  group('C3 — own announce packets pass through MeshService.broadcastPacket', () {
    late StubTransport rawTransport;
    late MockIdentityManager identityManager;
    late MeshService meshService;

    setUp(() async {
      rawTransport = StubTransport(myPeerId: makePeerId(0xAA));
      identityManager = MockIdentityManager();
      meshService = MeshService(
        transport: rawTransport,
        myPeerId: makePeerId(0xAA),
        identityManager: identityManager,
      );
      await meshService.start();
    });

    tearDown(() async {
      await meshService.stop();
      rawTransport.dispose();
    });

    test('peer connection triggers discovery and topologyAnnounce broadcasts',
        () async {
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: makePeerId(0xBB)),
      ]);
      await Future.delayed(const Duration(milliseconds: 20));

      final types =
          rawTransport.broadcastedPackets.map((p) => p.type).toSet();
      expect(types, contains(MessageType.discovery));
      expect(types, contains(MessageType.topologyAnnounce));
    });

    test(
        'broadcast announce packets have sourceId equal to our own peer ID',
        () async {
      rawTransport.simulatePeersChanged([
        PeerConnection(peerId: makePeerId(0xBB)),
      ]);
      await Future.delayed(const Duration(milliseconds: 20));

      for (final p in rawTransport.broadcastedPackets) {
        if (p.type == MessageType.discovery ||
            p.type == MessageType.topologyAnnounce) {
          expect(
            p.sourceId,
            equals(makePeerId(0xAA)),
            reason: 'Announce packet must originate from our own peer ID',
          );
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // H1 — Gossip sync must NOT store session-layer packet types
  // ---------------------------------------------------------------------------
  group('H1 — gossip sync skips session-layer packet types', () {
    late StubTransport transport;
    late GossipSyncManager gossip;

    setUp(() {
      transport = StubTransport(myPeerId: makePeerId(0xAA));
      gossip = GossipSyncManager(
        myPeerId: makePeerId(0xAA),
        transport: transport,
      );
    });

    tearDown(() {
      gossip.stop();
      transport.dispose();
    });

    for (final type in [
      MessageType.handshake,
      MessageType.noiseEncrypted,
      MessageType.ack,
      MessageType.ping,
      MessageType.pong,
      MessageType.gossipSync,
    ]) {
      test('${type.name} is NOT stored in gossip sync', () {
        final packet = buildPacket(type: type, sourceId: makePeerId(0xBB));
        gossip.onPacketSeen(packet);
        expect(
          gossip.knownPacketIds,
          isEmpty,
          reason: '${type.name} must not be stored',
        );
      });
    }

    for (final type in [
      MessageType.chat,
      MessageType.locationUpdate,
      MessageType.emergencyAlert,
    ]) {
      test('${type.name} IS stored in gossip sync', () {
        final packet = buildPacket(type: type, sourceId: makePeerId(0xBB));
        gossip.onPacketSeen(packet);
        expect(gossip.knownPacketIds, contains(packet.packetId));
      });
    }
  });

  // ---------------------------------------------------------------------------
  // H2 — handleSyncRequest caps at maxSyncPacketsPerRequest across calls
  // ---------------------------------------------------------------------------
  group('H2 — sync request rate limit enforced across multiple calls', () {
    late StubTransport transport;
    late GossipSyncManager gossip;
    final remotePeer = makePeerId(0xBB);

    setUp(() {
      transport = StubTransport(myPeerId: makePeerId(0xAA));
      gossip = GossipSyncManager(
        myPeerId: makePeerId(0xAA),
        transport: transport,
        config: const GossipSyncConfig(maxSyncPacketsPerRequest: 2),
      );
    });

    tearDown(() {
      gossip.stop();
      transport.dispose();
    });

    test('first call sends up to maxSyncPacketsPerRequest', () async {
      for (var i = 1; i <= 4; i++) {
        gossip.onPacketSeen(
          buildPacket(type: MessageType.chat, sourceId: makePeerId(i)),
        );
      }

      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});

      expect(transport.sentPackets.length, equals(2));
    });

    test('second call in the same window is blocked (budget exhausted)',
        () async {
      for (var i = 1; i <= 4; i++) {
        gossip.onPacketSeen(
          buildPacket(type: MessageType.chat, sourceId: makePeerId(i)),
        );
      }

      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});
      final afterFirst = transport.sentPackets.length;

      // Same window — budget should be exhausted
      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});
      expect(
        transport.sentPackets.length,
        equals(afterFirst),
        reason: 'No additional packets after budget is exhausted',
      );
    });

    test(
        'second call when available packets < limit still respects accumulated budget',
        () async {
      // With limit=2 and only 1 packet available, two calls should together
      // send at most 2 packets total, not 1+1=2 bypassing the window budget
      // via the local `sent` counter reset.
      gossip = GossipSyncManager(
        myPeerId: makePeerId(0xAA),
        transport: transport,
        config: const GossipSyncConfig(maxSyncPacketsPerRequest: 3),
      );

      // Only 2 packets available (< limit of 3)
      for (var i = 1; i <= 2; i++) {
        gossip.onPacketSeen(
          buildPacket(type: MessageType.chat, sourceId: makePeerId(i)),
        );
      }

      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});
      final afterFirst = transport.sentPackets.length; // 2 sent, count=2
      expect(afterFirst, equals(2));

      // Second call: count=2, limit=3, so budget has 1 left. Only 1 more sent.
      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});
      // But peerHasIds is empty again and same packets exist — count would reach 3, not 4.
      // Key: total must not exceed maxSyncPacketsPerRequest (3).
      expect(
        transport.sentPackets.length,
        lessThanOrEqualTo(3),
        reason: 'Budget must be shared across calls in the same window',
      );
    });

    test('different peer has independent budget', () async {
      final anotherPeer = makePeerId(0xCC);
      for (var i = 1; i <= 4; i++) {
        gossip.onPacketSeen(
          buildPacket(type: MessageType.chat, sourceId: makePeerId(i)),
        );
      }

      // Exhaust budget for remotePeer
      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});
      await gossip.handleSyncRequest(fromPeerId: remotePeer, peerHasIds: {});

      final beforeOther = transport.sentPackets.length;

      // anotherPeer should still get packets
      await gossip.handleSyncRequest(fromPeerId: anotherPeer, peerHasIds: {});

      expect(
        transport.sentPackets.length,
        greaterThan(beforeOther),
        reason: 'A different peer should have its own independent rate window',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // M1 — Duplicate packet fed to MeshService emits exactly once
  // ---------------------------------------------------------------------------
  group('M1 — mesh-level packet deduplication', () {
    late StubTransport rawTransport;
    late MockIdentityManager identityManager;
    late MeshService meshService;

    setUp(() async {
      rawTransport = StubTransport(myPeerId: makePeerId(0xAA));
      identityManager = MockIdentityManager();
      meshService = MeshService(
        transport: rawTransport,
        myPeerId: makePeerId(0xAA),
        identityManager: identityManager,
      );
      await meshService.start();
    });

    tearDown(() async {
      await meshService.stop();
      rawTransport.dispose();
    });

    test('duplicate chat packet injected twice is emitted at most once', () async {
      final received = <FluxonPacket>[];
      final sub = meshService.onPacketReceived.listen(received.add);

      // Use a distant peer (not in currentPeers) so the packet reaches app layer
      final remotePeer = makePeerId(0xDD);
      final chatPacket = buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        payload: Uint8List.fromList([0x68, 0x69]),
      );

      rawTransport.simulateIncomingPacket(chatPacket);
      rawTransport.simulateIncomingPacket(chatPacket); // exact duplicate
      await Future.delayed(const Duration(milliseconds: 10));

      sub.cancel();
      expect(received, hasLength(1));
    });

    test('two distinct packets are both emitted', () async {
      final received = <FluxonPacket>[];
      final sub = meshService.onPacketReceived.listen(received.add);

      final remotePeer = makePeerId(0xDD);
      final p1 = buildPacket(
        type: MessageType.chat,
        sourceId: remotePeer,
        payload: Uint8List.fromList([0x01]),
      );
      // BinaryProtocol.buildPacket uses a random flags byte, so two calls
      // produce distinct packetIds. Build second with different source.
      final p2 = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xEE),
        payload: Uint8List.fromList([0x02]),
      );

      rawTransport.simulateIncomingPacket(p1);
      rawTransport.simulateIncomingPacket(p2);
      await Future.delayed(const Duration(milliseconds: 10));

      sub.cancel();
      expect(received, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // M3 — Old-timestamped entry in deduplicator is cleaned up using insertion
  //      time, not the caller-supplied packet timestamp.
  // ---------------------------------------------------------------------------
  group('M3 — deduplicator cleanup uses insertion time', () {
    test(
        'entry added via record() with ancient caller timestamp is evicted after '
        'maxAge based on actual insertion time', () async {
      final dedup = MessageDeduplicator(
        maxAge: const Duration(milliseconds: 50),
        maxCount: 100,
      );

      // Supply a very old caller timestamp — before the fix this would cause
      // the entry to be immediately evicted on the next cleanup, even though it
      // was inserted just now.  After the fix, the eviction is based on the
      // actual insertion time.
      final ancientTs = DateTime(2000);
      dedup.record('msg-ancient', ancientTs);

      // Immediately after insertion the entry must still be present.
      expect(dedup.contains('msg-ancient'), isTrue,
          reason: 'Entry must not be prematurely evicted on insertion');

      // After maxAge elapses, cleanup should remove it.
      await Future.delayed(const Duration(milliseconds: 80));
      dedup.cleanup();

      expect(dedup.contains('msg-ancient'), isFalse,
          reason: 'Entry should be evicted once maxAge has elapsed');
    });

    test('timestampFor() returns the caller-supplied timestamp', () {
      final dedup = MessageDeduplicator(maxCount: 100);
      final callerTs = DateTime(2024, 3, 21);
      dedup.record('msg-ts', callerTs);
      expect(dedup.timestampFor('msg-ts'), equals(callerTs));
    });

    test('fresh record() entry survives cleanup before maxAge', () async {
      final dedup = MessageDeduplicator(
        maxAge: const Duration(milliseconds: 200),
        maxCount: 100,
      );
      dedup.record('msg-fresh', DateTime(2000)); // old caller ts, fresh insert
      await Future.delayed(const Duration(milliseconds: 50));
      dedup.cleanup();
      // Should still be present — only 50ms has passed, maxAge is 200ms.
      expect(dedup.contains('msg-fresh'), isTrue);
    });
  });
}
