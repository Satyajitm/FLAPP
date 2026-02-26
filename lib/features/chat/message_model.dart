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

  /// Serialize to a JSON-compatible map for local persistence.
  ///
  /// [deliveredTo] and [readBy] are transient session data and are not
  /// included in the serialized output.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender': sender.hex,
      'senderName': senderName,
      'text': text,
      'timestamp': timestamp.toIso8601String(),
      'isLocal': isLocal,
      'status': status.name,
    };
  }

  /// Deserialize a [ChatMessage] from a JSON map produced by [toJson].
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      sender: PeerId.fromHex(json['sender'] as String),
      senderName: json['senderName'] as String? ?? '',
      text: json['text'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isLocal: json['isLocal'] as bool? ?? false,
      status: MessageStatus.values.byName(json['status'] as String? ?? 'sent'),
    );
  }

  /// H13: Null-safe variant of [fromJson] that returns null on any error.
  ///
  /// Use when loading persisted messages to skip individual corrupt entries
  /// rather than crashing the entire message load.
  static ChatMessage? tryFromJson(Map<String, dynamic> json) {
    try {
      return ChatMessage.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
