import '../../core/identity/peer_id.dart';

/// Delivery/read status of a message.
enum MessageStatus {
  /// Message sent but no receipt received yet.
  sent,

  /// At least one peer has received the message.
  delivered,

  /// At least one peer has read the message.
  read,
}

/// A chat message in the mesh network.
class ChatMessage {
  /// Unique message ID (packet ID from the transport layer).
  final String id;

  /// Sender's peer ID.
  final PeerId sender;

  /// Sender's display name. Empty string if the peer is a legacy client that
  /// did not include a name, or if the name is not yet known.
  final String senderName;

  /// Message text content.
  final String text;

  /// When the message was created.
  final DateTime timestamp;

  /// Whether this message was sent by the local device.
  final bool isLocal;

  /// Current delivery/read status.
  final MessageStatus status;

  /// Peers who have sent a delivery receipt for this message.
  final Set<PeerId> deliveredTo;

  /// Peers who have sent a read receipt for this message.
  final Set<PeerId> readBy;

  const ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.senderName = '',
    this.isLocal = false,
    this.status = MessageStatus.sent,
    this.deliveredTo = const {},
    this.readBy = const {},
  });

  /// Whether this message has been delivered (acknowledged).
  /// Backward-compatible getter for existing code.
  bool get isDelivered =>
      status == MessageStatus.delivered || status == MessageStatus.read;

  /// Create a copy with updated receipt information.
  ChatMessage copyWith({
    MessageStatus? status,
    Set<PeerId>? deliveredTo,
    Set<PeerId>? readBy,
  }) {
    return ChatMessage(
      id: id,
      sender: sender,
      senderName: senderName,
      text: text,
      timestamp: timestamp,
      isLocal: isLocal,
      status: status ?? this.status,
      deliveredTo: deliveredTo ?? this.deliveredTo,
      readBy: readBy ?? this.readBy,
    );
  }
}
