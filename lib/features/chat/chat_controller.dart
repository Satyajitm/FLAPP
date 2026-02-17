import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import 'data/chat_repository.dart';
import 'message_model.dart';

const _sentinel = Object();

/// Chat state management.
class ChatState {
  final List<ChatMessage> messages;
  final bool isSending;
  final PeerId? selectedPeer; // null = broadcast mode, non-null = private message mode

  const ChatState({
    this.messages = const [],
    this.isSending = false,
    this.selectedPeer,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isSending,
    Object? selectedPeer = _sentinel,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isSending: isSending ?? this.isSending,
      selectedPeer: selectedPeer == _sentinel
          ? this.selectedPeer
          : selectedPeer as PeerId?,
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

  /// Send a chat message (broadcast to group or private to selected peer).
  ///
  /// Routing decision:
  /// - If [selectedPeer] is null: sends public broadcast message to all group members
  /// - If [selectedPeer] is non-null: sends private message via Noise session (end-to-end encrypted)
  Future<void> sendMessage(String text) async {
    state = state.copyWith(isSending: true);

    try {
      final message = state.selectedPeer != null
          ? await _repository.sendPrivateMessage(
              text: text,
              sender: _myPeerId,
              recipient: state.selectedPeer!,
            )
          : await _repository.sendMessage(
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

  /// Select a peer for private messaging, or null to return to broadcast mode.
  void selectPeer(PeerId? peer) {
    state = state.copyWith(selectedPeer: peer);
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
