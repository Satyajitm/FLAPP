import 'dart:async';
import '../../../core/identity/peer_id.dart';
import '../message_model.dart';

/// Abstract interface for chat data operations.
///
/// Decouples the [ChatController] from transport, protocol, and encryption
/// concerns. Implementations handle packet encoding/decoding and delivery.
abstract class ChatRepository {
  /// Stream of incoming chat messages, fully decoded and ready for display.
  Stream<ChatMessage> get onMessageReceived;

  /// Send a chat message text as a broadcast to all connected peers.
  ///
  /// [senderName] is the user's display name and is embedded in the payload so
  /// that recipients can show it alongside the message.
  ///
  /// Returns the [ChatMessage] that was sent (with its generated ID and
  /// timestamp) so the caller can perform an optimistic UI update.
  Future<ChatMessage> sendMessage({
    required String text,
    required PeerId sender,
    String senderName = '',
  });

  /// Send a private chat message to a specific peer via Noise session.
  ///
  /// Message is encrypted end-to-end using the established Noise session
  /// with the recipient. Only the recipient can decrypt it.
  ///
  /// Returns the [ChatMessage] that was sent (with its generated ID and
  /// timestamp) so the caller can perform an optimistic UI update.
  Future<ChatMessage> sendPrivateMessage({
    required String text,
    required PeerId sender,
    required PeerId recipient,
  });

  /// Release any resources held by this repository.
  void dispose();
}
