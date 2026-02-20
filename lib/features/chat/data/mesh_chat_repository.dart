import 'dart:async';
import 'dart:typed_data';
import '../../../core/identity/group_manager.dart';
import '../../../core/identity/peer_id.dart';
import '../../../core/protocol/binary_protocol.dart';
import '../../../core/protocol/message_types.dart';
import '../../../core/protocol/packet.dart';
import '../../../core/services/receipt_service.dart';
import '../../../core/transport/transport.dart';
import '../message_model.dart';
import 'chat_repository.dart';

/// Mesh-network implementation of [ChatRepository].
///
/// Listens for incoming [FluxonPacket]s of type [MessageType.chat] on the
/// [Transport] layer, decodes them via [BinaryProtocol], and exposes clean
/// [ChatMessage] objects. Sending follows the reverse path.
///
/// When the user is in a group, payloads are encrypted/decrypted with the
/// group key via [GroupManager], matching the pattern in
/// [MeshLocationRepository].
class MeshChatRepository implements ChatRepository {
  final Transport _transport;
  final PeerId? _myPeerId;
  final GroupManager _groupManager;
  final ReceiptService? _receiptService;
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  StreamSubscription? _packetSub;

  MeshChatRepository({
    required Transport transport,
    PeerId? myPeerId,
    GroupManager? groupManager,
    ReceiptService? receiptService,
  })  : _transport = transport,
        _myPeerId = myPeerId,
        _groupManager = groupManager ?? GroupManager(),
        _receiptService = receiptService {
    _listenForMessages();
  }

  void _listenForMessages() {
    _packetSub = _transport.onPacketReceived
        .where((p) => p.type == MessageType.chat || p.type == MessageType.noiseEncrypted)
        .listen(_handleIncomingPacket);
  }

  void _handleIncomingPacket(FluxonPacket packet) {
    final sender = PeerId(packet.sourceId);

    // Skip packets we sent ourselves (already added optimistically by controller)
    if (_myPeerId != null && sender == _myPeerId) return;

    // For noiseEncrypted: BleTransport already decrypted the payload via Noise session.
    // Skip group-key decrypt and use payload as-is.
    // For chat: decrypt with group key if in a group
    Uint8List payload = packet.payload;
    if (packet.type == MessageType.chat && _groupManager.isInGroup) {
      final decrypted = _groupManager.decryptFromGroup(payload);
      if (decrypted == null) return; // Not in our group — drop
      payload = decrypted;
    }

    final chatPayload = BinaryProtocol.decodeChatPayload(payload);

    final message = ChatMessage(
      id: packet.packetId,
      sender: sender,
      senderName: chatPayload.senderName,
      text: chatPayload.text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
      isLocal: false,
    );

    _messageController.add(message);

    // Auto-send delivery receipt
    _receiptService?.sendDeliveryReceipt(
      originalTimestamp: packet.timestamp,
      originalSenderId: packet.sourceId,
    );
  }

  @override
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;

  @override
  Stream<ReceiptEvent> get onReceiptReceived =>
      _receiptService?.onReceiptReceived ?? const Stream.empty();

  @override
  Future<ChatMessage> sendMessage({
    required String text,
    required PeerId sender,
    String senderName = '',
  }) async {
    var payload = BinaryProtocol.encodeChatPayload(text, senderName: senderName);

    // Encrypt with group key if in a group
    if (_groupManager.isInGroup) {
      final encrypted = _groupManager.encryptForGroup(payload);
      if (encrypted != null) payload = encrypted;
    }

    final packet = BinaryProtocol.buildPacket(
      type: MessageType.chat,
      sourceId: sender.bytes,
      payload: payload,
    );

    await _transport.broadcastPacket(packet);

    return ChatMessage(
      id: packet.packetId,
      sender: sender,
      senderName: senderName,
      text: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
      isLocal: true,
      status: MessageStatus.sent,
    );
  }

  @override
  Future<ChatMessage> sendPrivateMessage({
    required String text,
    required PeerId sender,
    required PeerId recipient,
  }) async {
    final payload = BinaryProtocol.encodeChatPayload(text);
    // No group-key encrypt: Noise session provides the encryption

    final packet = BinaryProtocol.buildPacket(
      type: MessageType.noiseEncrypted,
      sourceId: sender.bytes,
      destId: recipient.bytes,
      payload: payload,
    );

    await _transport.sendPacket(packet, recipient.bytes);

    return ChatMessage(
      id: packet.packetId,
      sender: sender,
      text: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
      isLocal: true,
      status: MessageStatus.sent,
    );
  }

  @override
  void sendReadReceipt({
    required String messageId,
    required int originalTimestamp,
    required Uint8List originalSenderId,
  }) {
    _receiptService?.queueReadReceipt(
      messageId: messageId,
      originalTimestamp: originalTimestamp,
      originalSenderId: originalSenderId,
    );
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _messageController.close();
  }
}
