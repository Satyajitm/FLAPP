import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:fluxon_app/features/chat/data/chat_repository.dart';
import 'package:fluxon_app/features/chat/data/mesh_chat_repository.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Mock Transport for testing
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

  /// Simulate receiving a packet from a peer.
  void simulateIncomingPacket(FluxonPacket packet) {
    _packetController.add(packet);
  }

  void dispose() {
    _packetController.close();
  }

  // --- Unused members for this test ---
  @override
  Stream<List<PeerConnection>> get connectedPeers =>
      const Stream.empty();
  @override
  bool get isRunning => true;
  @override
  Uint8List get myPeerId => Uint8List(32);
  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async =>
      true;
  @override
  Future<void> startServices() async {}
  @override
  Future<void> stopServices() async {}
}

// ---------------------------------------------------------------------------
// Helper to build a peer ID
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
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MeshChatRepository', () {
    late MockTransport transport;
    late MeshChatRepository repository;

    setUp(() {
      transport = MockTransport();
      repository = MeshChatRepository(transport: transport);
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('onMessageReceived emits decoded ChatMessage for incoming chat packets',
        () async {
      final packet = _buildChatPacket('Hello mesh!', senderByte: 0xBB);

      // Listen before simulating
      final future = repository.onMessageReceived.first;
      transport.simulateIncomingPacket(packet);

      final message = await future;
      expect(message.text, equals('Hello mesh!'));
      expect(message.sender, equals(_makePeerId(0xBB)));
      expect(message.isLocal, isFalse);
    });

    test('onMessageReceived ignores non-chat packets', () async {
      final locationPacket = BinaryProtocol.buildPacket(
        type: MessageType.locationUpdate,
        sourceId: Uint8List(32),
        payload: BinaryProtocol.encodeLocationPayload(
          latitude: 0, longitude: 0,
        ),
      );

      // Should not receive anything
      final completer = Completer<ChatMessage>();
      final sub = repository.onMessageReceived.listen(completer.complete);

      transport.simulateIncomingPacket(locationPacket);

      // Give it a moment to process, then verify nothing arrived
      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, isFalse);

      await sub.cancel();
    });

    test('sendMessage broadcasts packet and returns local ChatMessage',
        () async {
      final sender = _makePeerId(0xCC);
      final result = await repository.sendMessage(
        text: 'Test message',
        sender: sender,
      );

      // Verify the returned message
      expect(result.text, equals('Test message'));
      expect(result.sender, equals(sender));
      expect(result.isLocal, isTrue);
      expect(result.isDelivered, isTrue);
      expect(result.id, isNotEmpty);

      // Verify a packet was broadcast
      expect(transport.broadcastedPackets, hasLength(1));
      final sentPacket = transport.broadcastedPackets.first;
      expect(sentPacket.type, equals(MessageType.chat));

      // Verify payload round-trips correctly
      final decodedText =
          BinaryProtocol.decodeChatPayload(sentPacket.payload);
      expect(decodedText, equals('Test message'));
    });

    test('sendMessage handles Unicode text', () async {
      final sender = _makePeerId(0xDD);
      final result = await repository.sendMessage(
        text: '🚀 Hello 世界!',
        sender: sender,
      );
      expect(result.text, equals('🚀 Hello 世界!'));
    });

    test('multiple incoming messages arrive in order', () async {
      final messages = <ChatMessage>[];
      final sub = repository.onMessageReceived.listen(messages.add);

      transport.simulateIncomingPacket(
          _buildChatPacket('first', senderByte: 0x01));
      transport.simulateIncomingPacket(
          _buildChatPacket('second', senderByte: 0x02));
      transport.simulateIncomingPacket(
          _buildChatPacket('third', senderByte: 0x03));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(messages, hasLength(3));
      expect(messages[0].text, equals('first'));
      expect(messages[1].text, equals('second'));
      expect(messages[2].text, equals('third'));

      await sub.cancel();
    });
  });
}
