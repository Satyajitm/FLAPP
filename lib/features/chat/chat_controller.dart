import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import '../../core/protocol/binary_protocol.dart';
import '../../core/services/receipt_service.dart';
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

/// Chat controller — manages sending and receiving group chat messages.
///
/// All transport, protocol, and encryption details are delegated to the
/// injected [ChatRepository]. This controller is purely concerned with
/// application-level state management.
///
/// Only group broadcast messages are supported. One-to-one private messaging
/// is not a feature of FluxonApp.
class ChatController extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  final PeerId _myPeerId;
  final String Function() _getDisplayName;
  StreamSubscription? _messageSub;
  StreamSubscription? _receiptSub;

  ChatController({
    required ChatRepository repository,
    required PeerId myPeerId,
    required String Function() getDisplayName,
  })  : _repository = repository,
        _myPeerId = myPeerId,
        _getDisplayName = getDisplayName,
        super(const ChatState()) {
    _listenForMessages();
    _listenForReceipts();
  }

  void _listenForMessages() {
    _messageSub = _repository.onMessageReceived.listen((message) {
      state = state.copyWith(
        messages: [...state.messages, message],
      );
    });
  }

  void _listenForReceipts() {
    _receiptSub = _repository.onReceiptReceived.listen((receipt) {
      _handleReceipt(receipt);
    });
  }

  void _handleReceipt(ReceiptEvent receipt) {
    final messages = [...state.messages];
    final index = messages.indexWhere((m) => m.id == receipt.originalMessageId);
    if (index == -1) return;

    final msg = messages[index];
    if (!msg.isLocal) return; // Only update status on our own messages

    final newDeliveredTo = {...msg.deliveredTo};
    final newReadBy = {...msg.readBy};
    var newStatus = msg.status;

    if (receipt.receiptType == ReceiptType.delivered) {
      newDeliveredTo.add(receipt.fromPeer);
      if (newStatus == MessageStatus.sent) {
        newStatus = MessageStatus.delivered;
      }
    } else if (receipt.receiptType == ReceiptType.read) {
      newReadBy.add(receipt.fromPeer);
      newDeliveredTo.add(receipt.fromPeer); // read implies delivered
      newStatus = MessageStatus.read;
    }

    messages[index] = msg.copyWith(
      status: newStatus,
      deliveredTo: newDeliveredTo,
      readBy: newReadBy,
    );

    state = state.copyWith(messages: messages);
  }

  /// Mark incoming messages as read and send read receipts.
  ///
  /// Called when the chat screen is visible and messages are displayed.
  void markMessagesAsRead(List<ChatMessage> visibleMessages) {
    for (final msg in visibleMessages) {
      if (!msg.isLocal) {
        _repository.sendReadReceipt(
          messageId: msg.id,
          originalTimestamp: msg.timestamp.millisecondsSinceEpoch,
          originalSenderId: msg.sender.bytes,
        );
      }
    }
  }

  /// Send a chat message to all group members.
  Future<void> sendMessage(String text) async {
    state = state.copyWith(isSending: true);

    try {
      final message = await _repository.sendMessage(
        text: text,
        sender: _myPeerId,
        senderName: _getDisplayName(),
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
    _receiptSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
