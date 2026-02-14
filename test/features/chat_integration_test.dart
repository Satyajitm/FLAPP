import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/features/chat/data/mesh_chat_repository.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

FluxonPacket _buildChatPacket(String text, {int senderByte = 0xAA}) {
  return BinaryProtocol.buildPacket(
    type: MessageType.chat,
    sourceId: Uint8List(32)..fillRange(0, 32, senderByte),
    payload: BinaryProtocol.encodeChatPayload(text),
  );
}

// ---------------------------------------------------------------------------
// Integration tests: StubTransport loopback + MeshChatRepository
// ---------------------------------------------------------------------------

void main() {
  group('Chat integration — StubTransport loopback + MeshChatRepository', () {
    late StubTransport transport;
    late MeshChatRepository repository;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      transport = StubTransport(
        myPeerId: myPeerId.bytes,
        loopback: true,
      );
      repository = MeshChatRepository(
        transport: transport,
        myPeerId: myPeerId,
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('sendMessage with loopback: self-sourced echo is filtered', () async {
      // With loopback, broadcastPacket echoes the packet back. The repository
      // should filter it since sourceId matches myPeerId.
      final messages = <ChatMessage>[];
      final sub = repository.onMessageReceived.listen(messages.add);

      final sentMsg = await repository.sendMessage(
        text: 'hello',
        sender: myPeerId,
      );

      await Future.delayed(const Duration(milliseconds: 50));

      // The echo from loopback should be filtered — no incoming messages
      expect(messages, isEmpty);
      // But the returned local message is still valid
      expect(sentMsg.text, equals('hello'));
      expect(sentMsg.isLocal, isTrue);

      await sub.cancel();
    });

    test('simulateIncomingPacket from remote peer arrives normally', () async {
      final packet = _buildChatPacket('remote msg', senderByte: 0xBB);
      final future = repository.onMessageReceived.first;

      transport.simulateIncomingPacket(packet);

      final msg = await future;
      expect(msg.text, equals('remote msg'));
      expect(msg.sender, equals(_makePeerId(0xBB)));
      expect(msg.isLocal, isFalse);
    });

    test('mixed local send + remote receive: only remote appears in stream',
        () async {
      final messages = <ChatMessage>[];
      final sub = repository.onMessageReceived.listen(messages.add);

      // Local send (echoed back by loopback, filtered by self-source check)
      await repository.sendMessage(text: 'local', sender: myPeerId);

      // Remote packet
      transport.simulateIncomingPacket(
          _buildChatPacket('remote', senderByte: 0xCC));

      // Another local send
      await repository.sendMessage(text: 'local2', sender: myPeerId);

      await Future.delayed(const Duration(milliseconds: 50));

      // Only the remote message should appear
      expect(messages, hasLength(1));
      expect(messages[0].text, equals('remote'));

      await sub.cancel();
    });
  });

  group('Chat integration — two peers via StubTransport', () {
    test('two repositories with separate transports simulate peer chat',
        () async {
      // Simulate two phones: each has its own transport and repository
      final peerA = _makePeerId(0xAA);
      final peerB = _makePeerId(0xBB);

      final transportA = StubTransport(myPeerId: peerA.bytes);
      final transportB = StubTransport(myPeerId: peerB.bytes);

      final repoA = MeshChatRepository(
        transport: transportA,
        myPeerId: peerA,
      );
      final repoB = MeshChatRepository(
        transport: transportB,
        myPeerId: peerB,
      );

      // Phone A sends a message — simulate it arriving on Phone B's transport
      final futureB = repoB.onMessageReceived.first;
      final sentByA = await repoA.sendMessage(text: 'hi B!', sender: peerA);

      // Manually deliver the broadcast packet from A to B's transport
      // (in real BLE, this happens over the air)
      transportB.simulateIncomingPacket(
        _buildChatPacket('hi B!', senderByte: 0xAA),
      );

      final receivedByB = await futureB;
      expect(receivedByB.text, equals('hi B!'));
      expect(receivedByB.sender, equals(peerA));
      expect(receivedByB.isLocal, isFalse);
      expect(sentByA.isLocal, isTrue);

      // Phone B replies — simulate it arriving on Phone A's transport
      final futureA = repoA.onMessageReceived.first;
      await repoB.sendMessage(text: 'hey A!', sender: peerB);

      transportA.simulateIncomingPacket(
        _buildChatPacket('hey A!', senderByte: 0xBB),
      );

      final receivedByA = await futureA;
      expect(receivedByA.text, equals('hey A!'));
      expect(receivedByA.sender, equals(peerB));
      expect(receivedByA.isLocal, isFalse);

      repoA.dispose();
      repoB.dispose();
      transportA.dispose();
      transportB.dispose();
    });
  });
}
