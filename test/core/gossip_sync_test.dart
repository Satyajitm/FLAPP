import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/mesh/gossip_sync.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';

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

  group('GossipSyncManager onPacketSeen', () {
    test('first packet is stored and appears in knownPacketIds', () {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
      );

      gossip.onPacketSeen(packet);

      expect(gossip.knownPacketIds, contains(packet.packetId));
      expect(gossip.knownPacketIds, hasLength(1));
    });

    test('duplicate packet ID is ignored', () {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
      );

      gossip.onPacketSeen(packet);
      gossip.onPacketSeen(packet);

      expect(gossip.knownPacketIds, hasLength(1));
    });

    test('multiple distinct packets are all stored', () {
      final p1 = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
      );
      // Small delay to get different timestamp
      final p2 = buildPacket(
        type: MessageType.locationUpdate,
        sourceId: makePeerId(0xCC),
      );

      gossip.onPacketSeen(p1);
      gossip.onPacketSeen(p2);

      expect(gossip.knownPacketIds, hasLength(2));
      expect(gossip.knownPacketIds, contains(p1.packetId));
      expect(gossip.knownPacketIds, contains(p2.packetId));
    });

    test('capacity enforcement evicts oldest packet', () {
      final smallGossip = GossipSyncManager(
        myPeerId: makePeerId(0xAA),
        transport: transport,
        config: const GossipSyncConfig(seenCapacity: 3),
      );

      final packets = <FluxonPacket>[];
      for (var i = 0; i < 5; i++) {
        final p = buildPacket(
          type: MessageType.chat,
          sourceId: makePeerId(i + 1),
        );
        packets.add(p);
        smallGossip.onPacketSeen(p);
      }

      // Should only have the last 3
      expect(smallGossip.knownPacketIds, hasLength(3));
      expect(smallGossip.knownPacketIds, isNot(contains(packets[0].packetId)));
      expect(smallGossip.knownPacketIds, isNot(contains(packets[1].packetId)));
      expect(smallGossip.knownPacketIds, contains(packets[2].packetId));
      expect(smallGossip.knownPacketIds, contains(packets[3].packetId));
      expect(smallGossip.knownPacketIds, contains(packets[4].packetId));

      smallGossip.stop();
    });
  });

  group('GossipSyncManager handleSyncRequest', () {
    test('sends missing packets to requesting peer', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xCC),
      );

      gossip.onPacketSeen(packet);

      await gossip.handleSyncRequest(
        fromPeerId: remotePeer,
        peerHasIds: {},
      );

      expect(transport.sentPackets, hasLength(1));
      expect(transport.sentPackets.first.$2, equals(remotePeer));
    });

    test('skips packets the peer already has', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xCC),
      );

      gossip.onPacketSeen(packet);

      await gossip.handleSyncRequest(
        fromPeerId: remotePeer,
        peerHasIds: {packet.packetId},
      );

      expect(transport.sentPackets, isEmpty);
    });

    test('sends with decremented TTL', () async {
      final remotePeer = makePeerId(0xBB);
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xCC),
        ttl: 5,
      );

      gossip.onPacketSeen(packet);

      await gossip.handleSyncRequest(
        fromPeerId: remotePeer,
        peerHasIds: {},
      );

      expect(transport.sentPackets, hasLength(1));
      expect(transport.sentPackets.first.$1.ttl, equals(4));
    });

    test('sends nothing when peer has all packets', () async {
      final remotePeer = makePeerId(0xBB);
      final p1 = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xCC),
      );
      final p2 = buildPacket(
        type: MessageType.locationUpdate,
        sourceId: makePeerId(0xDD),
      );

      gossip.onPacketSeen(p1);
      gossip.onPacketSeen(p2);

      await gossip.handleSyncRequest(
        fromPeerId: remotePeer,
        peerHasIds: {p1.packetId, p2.packetId},
      );

      expect(transport.sentPackets, isEmpty);
    });

    test('sends only missing packets from a mixed set', () async {
      final remotePeer = makePeerId(0xBB);
      final p1 = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xCC),
      );
      final p2 = buildPacket(
        type: MessageType.locationUpdate,
        sourceId: makePeerId(0xDD),
      );

      gossip.onPacketSeen(p1);
      gossip.onPacketSeen(p2);

      await gossip.handleSyncRequest(
        fromPeerId: remotePeer,
        peerHasIds: {p1.packetId},
      );

      expect(transport.sentPackets, hasLength(1));
      // Should be the location update packet (the one peer is missing)
      expect(
        transport.sentPackets.first.$1.type,
        equals(MessageType.locationUpdate),
      );
    });
  });

  group('GossipSyncManager knownPacketIds', () {
    test('empty initially', () {
      expect(gossip.knownPacketIds, isEmpty);
    });

    test('returns a set copy (not mutable reference)', () {
      final packet = buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
      );
      gossip.onPacketSeen(packet);

      final ids = gossip.knownPacketIds;
      ids.add('fake-id');

      // Internal state should not be affected
      expect(gossip.knownPacketIds, hasLength(1));
    });
  });

  group('GossipSyncManager reset', () {
    test('clears all stored packets', () {
      gossip.onPacketSeen(buildPacket(
        type: MessageType.chat,
        sourceId: makePeerId(0xBB),
      ));
      gossip.onPacketSeen(buildPacket(
        type: MessageType.locationUpdate,
        sourceId: makePeerId(0xCC),
      ));

      expect(gossip.knownPacketIds, hasLength(2));

      gossip.reset();

      expect(gossip.knownPacketIds, isEmpty);
    });
  });

  group('GossipSyncManager start/stop', () {
    test('stop before start is safe (no-op)', () {
      // Should not throw
      gossip.stop();
    });

    test('start then stop then start is idempotent', () {
      gossip.start();
      gossip.stop();
      gossip.start();
      gossip.stop();
      // No assertion needed — just verifying no exceptions
    });
  });

  group('GossipSyncConfig', () {
    test('default values are correct', () {
      const config = GossipSyncConfig();
      expect(config.seenCapacity, equals(1000));
      expect(config.maxMessageAgeSeconds, equals(900));
      expect(config.maintenanceIntervalSeconds, equals(60));
      expect(config.syncIntervalSeconds, equals(15));
    });

    test('custom values are respected', () {
      const config = GossipSyncConfig(
        seenCapacity: 50,
        maxMessageAgeSeconds: 60,
        maintenanceIntervalSeconds: 5,
        syncIntervalSeconds: 3,
      );
      expect(config.seenCapacity, equals(50));
      expect(config.maxMessageAgeSeconds, equals(60));
      expect(config.maintenanceIntervalSeconds, equals(5));
      expect(config.syncIntervalSeconds, equals(3));
    });
  });
}
