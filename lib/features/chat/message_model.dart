import '../../core/identity/peer_id.dart';

/// A chat message in the mesh network.
class ChatMessage {
  /// Unique message ID (packet ID from the transport layer).
  final String id;

  /// Sender's peer ID.
  final PeerId sender;

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
    this.isLocal = false,
    this.isDelivered = false,
  });
}
