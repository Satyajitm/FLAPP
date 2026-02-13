import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import 'data/chat_repository.dart';
import 'message_model.dart';

/// Chat state management.
class ChatState {
  final List<ChatMessage> messages;
  final bool isSending;

  const ChatState({
    this.messages = const [],
    this.isSending = false,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isSending,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isSending: isSending ?? this.isSending,
    );
  }
}

/// Chat controller — manages sending and receiving chat messages.
///
/// All transport, protocol, and encryption details are delegated to the
/// injected [ChatRepository]. This controller is purely concerned with
/// application-level state management.
class ChatController extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  final PeerId _myPeerId;
  StreamSubscription? _messageSub;

  ChatController({
    required ChatRepository repository,
    required PeerId myPeerId,
  })  : _repository = repository,
        _myPeerId = myPeerId,
        super(const ChatState()) {
    _listenForMessages();
  }

  void _listenForMessages() {
    _messageSub = _repository.onMessageReceived.listen((message) {
      state = state.copyWith(
        messages: [...state.messages, message],
      );
    });
  }

  /// Send a chat message to the group (broadcast).
  Future<void> sendMessage(String text) async {
    state = state.copyWith(isSending: true);

    try {
      final message = await _repository.sendMessage(
        text: text,
        sender: _myPeerId,
      );

      state = state.copyWith(
        messages: [...state.messages, message],
        isSending: false,
      );
    } catch (_) {
      state = state.copyWith(isSending: false);
    }
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
