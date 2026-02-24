import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import '../../core/protocol/binary_protocol.dart';
import '../../core/services/message_storage_service.dart';
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
/// Messages are persisted to local storage via [MessageStorageService],
/// partitioned by group ID, and survive app restarts. They remain until
/// the user explicitly deletes them.
///
/// Only group broadcast messages are supported. One-to-one private messaging
/// is not a feature of FluxonApp.
class ChatController extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  final PeerId _myPeerId;
  final String Function() _getDisplayName;
  final MessageStorageService? _storageService;
  final String? _groupId;
  StreamSubscription? _messageSub;
  StreamSubscription? _receiptSub;

  ChatController({
    required ChatRepository repository,
    required PeerId myPeerId,
    required String Function() getDisplayName,
    MessageStorageService? storageService,
    String? groupId,
  })  : _repository = repository,
        _myPeerId = myPeerId,
        _getDisplayName = getDisplayName,
        _storageService = storageService,
        _groupId = groupId,
        super(const ChatState()) {
    _loadPersistedMessages();
    _listenForMessages();
    _listenForReceipts();
  }

  /// Restore messages saved from a previous session for the active group.
  Future<void> _loadPersistedMessages() async {
    if (_storageService == null || _groupId == null) return;
    final saved = await _storageService.loadMessages(_groupId);
    if (saved.isNotEmpty) {
      final capped = saved.length > _maxInMemoryMessages
          ? saved.sublist(saved.length - _maxInMemoryMessages)
          : saved;
      state = state.copyWith(messages: capped);
    }
  }

  /// Save the current message list to disk.
  ///
  /// Errors (e.g. disk full) are caught and logged; messages remain in memory.
  Future<void> _persistMessages() async {
    if (_groupId == null) return;
    try {
      await _storageService?.saveMessages(_groupId, state.messages);
    } catch (_) {
      // Disk write failed — messages remain in memory for this session.
    }
  }

  void _listenForMessages() {
    _messageSub = _repository.onMessageReceived.listen((message) async {
      final updated = [...state.messages, message];
      // Cap in-memory list at 200; older messages remain on disk.
      final capped = updated.length > _maxInMemoryMessages
          ? updated.sublist(updated.length - _maxInMemoryMessages)
          : updated;
      state = state.copyWith(messages: capped);
      await _persistMessages();
    });
  }

  static const _maxInMemoryMessages = 200;

  void _listenForReceipts() {
    _receiptSub = _repository.onReceiptReceived.listen((receipt) async {
      await _handleReceipt(receipt);
    });
  }

  Future<void> _handleReceipt(ReceiptEvent receipt) async {
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

    // Only update state and persist if something actually changed.
    if (newStatus == msg.status &&
        newDeliveredTo.length == msg.deliveredTo.length &&
        newReadBy.length == msg.readBy.length) {
      return;
    }

    messages[index] = msg.copyWith(
      status: newStatus,
      deliveredTo: newDeliveredTo,
      readBy: newReadBy,
    );

    state = state.copyWith(messages: messages);
    // Receipt status changes (delivered/read ticks) are persisted lazily —
    // the debounced MessageStorageService write is sufficient here.
    _storageService?.saveMessages(_groupId ?? '', state.messages);
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

      final updated = [...state.messages, message];
      final capped = updated.length > _maxInMemoryMessages
          ? updated.sublist(updated.length - _maxInMemoryMessages)
          : updated;
      state = state.copyWith(messages: capped, isSending: false);
      await _persistMessages();
    } catch (_) {
      state = state.copyWith(isSending: false);
    }
  }

  /// Delete a single message by its ID.
  Future<void> deleteMessage(String id) async {
    final filtered = state.messages.where((m) => m.id != id).toList();
    state = state.copyWith(messages: filtered);
    await _persistMessages();
  }

  /// Delete all messages for the active group and remove the persisted file.
  Future<void> clearAllMessages() async {
    state = state.copyWith(messages: []);
    if (_groupId != null) {
      await _storageService?.deleteAllMessages(_groupId);
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
