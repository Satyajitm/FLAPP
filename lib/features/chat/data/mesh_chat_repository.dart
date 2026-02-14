import 'dart:async';
import '../../../core/identity/peer_id.dart';
import '../../../core/protocol/binary_protocol.dart';
import '../../../core/protocol/message_types.dart';
import '../../../core/protocol/packet.dart';
import '../../../core/transport/transport.dart';
import '../message_model.dart';
import 'chat_repository.dart';

/// Mesh-network implementation of [ChatRepository].
///
/// Listens for incoming [FluxonPacket]s of type [MessageType.chat] on the
/// [Transport] layer, decodes them via [BinaryProtocol], and exposes clean
/// [ChatMessage] objects. Sending follows the reverse path.
class MeshChatRepository implements ChatRepository {
  final Transport _transport;
  final PeerId? _myPeerId;
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  StreamSubscription? _packetSub;

  MeshChatRepository({required Transport transport, PeerId? myPeerId})
      : _transport = transport,
        _myPeerId = myPeerId {
    _listenForMessages();
  }

  void _listenForMessages() {
    _packetSub = _transport.onPacketReceived
        .where((p) => p.type == MessageType.chat)
        .listen(_handleIncomingPacket);
  }

  void _handleIncomingPacket(FluxonPacket packet) {
    final sender = PeerId(packet.sourceId);

    // Skip packets we sent ourselves (already added optimistically by controller)
    if (_myPeerId != null && sender == _myPeerId) return;

    final text = BinaryProtocol.decodeChatPayload(packet.payload);

    final message = ChatMessage(
      id: packet.packetId,
      sender: sender,
      text: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
      isLocal: false,
    );

    _messageController.add(message);
  }

  @override
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;

  @override
  Future<ChatMessage> sendMessage({
    required String text,
    required PeerId sender,
  }) async {
    final payload = BinaryProtocol.encodeChatPayload(text);
    final packet = BinaryProtocol.buildPacket(
      type: MessageType.chat,
      sourceId: sender.bytes,
      payload: payload,
    );

    await _transport.broadcastPacket(packet);

    return ChatMessage(
      id: packet.packetId,
      sender: sender,
      text: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
      isLocal: true,
      isDelivered: true,
    );
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _messageController.close();
  }
}
