import '../../core/identity/peer_id.dart';

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

  /// Whether this message has been delivered (acknowledged).
  bool isDelivered;

  ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.senderName = '',
    this.isLocal = false,
    this.isDelivered = false,
  });
}
