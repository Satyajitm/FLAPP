import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/services/receipt_service.dart';
import 'package:fluxon_app/features/chat/chat_controller.dart';
import 'package:fluxon_app/features/chat/data/chat_repository.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Fake ChatRepository for testing the Controller in isolation
// ---------------------------------------------------------------------------

class FakeChatRepository implements ChatRepository {
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<ReceiptEvent> _receiptController =
      StreamController<ReceiptEvent>.broadcast();
  final List<String> sentMessages = [];
  bool shouldFailOnSend = false;

  @override
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;

  @override
  Stream<ReceiptEvent> get onReceiptReceived => _receiptController.stream;

  @override
  Future<ChatMessage> sendMessage({
    required String text,
    required PeerId sender,
    String senderName = '',
  }) async {
    if (shouldFailOnSend) {
      throw Exception('Send failed');
    }
    sentMessages.add(text);
    return ChatMessage(
      id: 'msg-${sentMessages.length}',
      sender: sender,
      senderName: senderName,
      text: text,
      timestamp: DateTime.now(),
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
    if (shouldFailOnSend) {
      throw Exception('Send failed');
    }
    sentMessages.add(text);
    return ChatMessage(
      id: 'msg-${sentMessages.length}',
      sender: sender,
      text: text,
      timestamp: DateTime.now(),
      isLocal: true,
      status: MessageStatus.sent,
    );
  }

  @override
  void sendReadReceipt({
    required String messageId,
    required int originalTimestamp,
    required Uint8List originalSenderId,
  }) {}

  /// Simulate an incoming message from a remote peer.
  void simulateIncoming(ChatMessage message) {
    _messageController.add(message);
  }

  /// Simulate an incoming receipt event.
  void simulateReceipt(ReceiptEvent receipt) {
    _receiptController.add(receipt);
  }

  @override
  void dispose() {
    _messageController.close();
    _receiptController.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

ChatMessage _makeRemoteMessage(String text, {int senderByte = 0xBB}) {
  return ChatMessage(
    id: 'incoming-${text.hashCode}',
    sender: _makePeerId(senderByte),
    text: text,
    timestamp: DateTime.now(),
    isLocal: false,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatController', () {
    late FakeChatRepository repository;
    late ChatController controller;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      repository = FakeChatRepository();
      controller = ChatController(
        repository: repository,
        myPeerId: myPeerId,
        getDisplayName: () => 'TestUser',
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('initial state has empty messages and isSending=false', () {
      expect(controller.state.messages, isEmpty);
      expect(controller.state.isSending, isFalse);
    });

    test('incoming messages from repository are added to state', () async {
      final msg = _makeRemoteMessage('Hello!');
      repository.simulateIncoming(msg);

      // Allow microtask to complete
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.messages, hasLength(1));
      expect(controller.state.messages.first.text, equals('Hello!'));
      expect(controller.state.messages.first.isLocal, isFalse);
    });

    test('multiple incoming messages accumulate in order', () async {
      repository.simulateIncoming(_makeRemoteMessage('one'));
      repository.simulateIncoming(_makeRemoteMessage('two'));
      repository.simulateIncoming(_makeRemoteMessage('three'));

      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.messages, hasLength(3));
      expect(controller.state.messages[0].text, equals('one'));
      expect(controller.state.messages[1].text, equals('two'));
      expect(controller.state.messages[2].text, equals('three'));
    });

    test('sendMessage delegates to repository and adds message to state',
        () async {
      await controller.sendMessage('outgoing');

      expect(repository.sentMessages, equals(['outgoing']));
      expect(controller.state.messages, hasLength(1));
      expect(controller.state.messages.first.text, equals('outgoing'));
      expect(controller.state.messages.first.isLocal, isTrue);
      expect(controller.state.isSending, isFalse);
    });

    test('sendMessage sets isSending=false after failure', () async {
      repository.shouldFailOnSend = true;

      await controller.sendMessage('will fail');

      // Message should NOT be added to state on failure
      expect(controller.state.messages, isEmpty);
      expect(controller.state.isSending, isFalse);
    });

    test('mixing incoming and outgoing messages', () async {
      repository.simulateIncoming(_makeRemoteMessage('hello from peer'));
      await Future.delayed(const Duration(milliseconds: 20));

      await controller.sendMessage('hello back');

      expect(controller.state.messages, hasLength(2));
      expect(controller.state.messages[0].text, equals('hello from peer'));
      expect(controller.state.messages[0].isLocal, isFalse);
      expect(controller.state.messages[1].text, equals('hello back'));
      expect(controller.state.messages[1].isLocal, isTrue);
    });

    test('copyWith preserves messages when only isSending changes', () {
      // Verify copyWith leaves messages intact when only isSending changes
      final newState = controller.state.copyWith(isSending: true);
      expect(newState.messages, equals(controller.state.messages));
      expect(newState.isSending, isTrue);
    });
  });

  group('ChatController — receipt handling', () {
    late FakeChatRepository repository;
    late ChatController controller;
    final myPeerId = _makePeerId(0xAA);
    final remotePeerId = _makePeerId(0xBB);

    setUp(() {
      repository = FakeChatRepository();
      controller = ChatController(
        repository: repository,
        myPeerId: myPeerId,
        getDisplayName: () => 'TestUser',
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('delivery receipt updates message status to delivered', () async {
      await controller.sendMessage('test message');
      final msg = controller.state.messages.first;
      expect(msg.status, equals(MessageStatus.sent));

      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01, // delivered
        fromPeer: remotePeerId,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.delivered));
      expect(updated.deliveredTo, contains(remotePeerId));
    });

    test('read receipt updates message status to read', () async {
      await controller.sendMessage('test message');
      final msg = controller.state.messages.first;

      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x02, // read
        fromPeer: remotePeerId,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.read));
      expect(updated.readBy, contains(remotePeerId));
      expect(updated.deliveredTo, contains(remotePeerId));
    });

    test('receipt for unknown message is ignored', () async {
      await controller.sendMessage('test');
      final messagesBefore = controller.state.messages.length;

      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: 'nonexistent-id',
        receiptType: 0x01,
        fromPeer: remotePeerId,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.messages.length, equals(messagesBefore));
    });

    test('receipt for incoming (non-local) message is ignored', () async {
      final incoming = _makeRemoteMessage('from peer');
      repository.simulateIncoming(incoming);
      await Future.delayed(const Duration(milliseconds: 20));

      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: incoming.id,
        receiptType: 0x01,
        fromPeer: _makePeerId(0xCC),
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      // Status should remain sent (default for non-local)
      expect(controller.state.messages.first.status, equals(MessageStatus.sent));
    });

    test('multiple delivery receipts from different peers accumulate', () async {
      await controller.sendMessage('test');
      final msg = controller.state.messages.first;

      final peerC = _makePeerId(0xCC);
      final peerD = _makePeerId(0xDD);

      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: remotePeerId,
      ));
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: peerC,
      ));
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: peerD,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      final updated = controller.state.messages.first;
      expect(updated.deliveredTo, hasLength(3));
      expect(updated.deliveredTo, containsAll([remotePeerId, peerC, peerD]));
    });

    test('read receipt implies delivered (adds to deliveredTo too)', () async {
      await controller.sendMessage('test');
      final msg = controller.state.messages.first;

      // Send only a read receipt (no prior delivery receipt)
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x02, // read
        fromPeer: remotePeerId,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.read));
      expect(updated.readBy, contains(remotePeerId));
      // Read implies delivered
      expect(updated.deliveredTo, contains(remotePeerId));
    });

    test('delivery receipt does not downgrade read status', () async {
      await controller.sendMessage('test');
      final msg = controller.state.messages.first;

      // First: read receipt
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x02,
        fromPeer: remotePeerId,
      ));
      await Future.delayed(const Duration(milliseconds: 20));
      expect(controller.state.messages.first.status, equals(MessageStatus.read));

      // Then: late delivery receipt from same peer
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: remotePeerId,
      ));
      await Future.delayed(const Duration(milliseconds: 20));

      // Status should still be read (not downgraded to delivered)
      // because _handleReceipt only upgrades from sent→delivered
      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.read));
    });

    test('duplicate receipt from same peer does not duplicate in set', () async {
      await controller.sendMessage('test');
      final msg = controller.state.messages.first;

      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: remotePeerId,
      ));
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: remotePeerId,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      final updated = controller.state.messages.first;
      expect(updated.deliveredTo, hasLength(1));
    });

    test('mixed delivery + read from different peers', () async {
      await controller.sendMessage('test');
      final msg = controller.state.messages.first;

      final peerC = _makePeerId(0xCC);

      // Peer B delivers
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x01,
        fromPeer: remotePeerId,
      ));
      // Peer C reads (implying delivery)
      repository.simulateReceipt(ReceiptEvent(
        originalMessageId: msg.id,
        receiptType: 0x02,
        fromPeer: peerC,
      ));

      await Future.delayed(const Duration(milliseconds: 20));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.read));
      expect(updated.deliveredTo, containsAll([remotePeerId, peerC]));
      expect(updated.readBy, hasLength(1));
      expect(updated.readBy, contains(peerC));
    });
  });

  group('ChatController — markMessagesAsRead', () {
    late _TrackingChatRepository repository;
    late ChatController controller;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      repository = _TrackingChatRepository();
      controller = ChatController(
        repository: repository,
        myPeerId: myPeerId,
        getDisplayName: () => 'TestUser',
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('markMessagesAsRead sends read receipts for non-local messages',
        () async {
      final incoming1 = _makeRemoteMessage('msg1', senderByte: 0xBB);
      final incoming2 = _makeRemoteMessage('msg2', senderByte: 0xCC);
      repository.simulateIncoming(incoming1);
      repository.simulateIncoming(incoming2);
      await Future.delayed(const Duration(milliseconds: 20));

      controller.markMessagesAsRead(controller.state.messages);

      expect(repository.readReceiptsSent, hasLength(2));
      expect(repository.readReceiptsSent[0].messageId, equals(incoming1.id));
      expect(repository.readReceiptsSent[1].messageId, equals(incoming2.id));
    });

    test('markMessagesAsRead skips local messages', () async {
      await controller.sendMessage('my message');
      await Future.delayed(const Duration(milliseconds: 20));

      controller.markMessagesAsRead(controller.state.messages);

      expect(repository.readReceiptsSent, isEmpty);
    });

    test('markMessagesAsRead handles mix of local and remote', () async {
      // Remote message first
      repository.simulateIncoming(_makeRemoteMessage('remote', senderByte: 0xBB));
      await Future.delayed(const Duration(milliseconds: 20));

      // Then local
      await controller.sendMessage('local');

      controller.markMessagesAsRead(controller.state.messages);

      // Only the remote message should trigger a read receipt
      expect(repository.readReceiptsSent, hasLength(1));
    });

    test('markMessagesAsRead with empty list does nothing', () {
      controller.markMessagesAsRead([]);
      expect(repository.readReceiptsSent, isEmpty);
    });
  });

  group('ChatController — in-memory message cap', () {
    late FakeChatRepository repository;
    late ChatController controller;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      repository = FakeChatRepository();
      controller = ChatController(
        repository: repository,
        myPeerId: myPeerId,
        getDisplayName: () => 'TestUser',
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('incoming messages beyond 200 trim the oldest entries', () async {
      // Simulate 201 incoming messages
      for (var i = 0; i < 201; i++) {
        repository.simulateIncoming(_makeRemoteMessage('msg$i'));
      }
      await Future.delayed(const Duration(milliseconds: 40));

      // Must never exceed the 200 cap
      expect(controller.state.messages.length, equals(200));
      // The oldest message (msg0) should have been dropped
      expect(
        controller.state.messages.any((m) => m.text == 'msg0'),
        isFalse,
        reason: 'msg0 should have been evicted',
      );
      // The most recent message should still be present
      expect(
        controller.state.messages.last.text,
        equals('msg200'),
      );
    });

    test('exactly 200 messages are kept without trimming', () async {
      for (var i = 0; i < 200; i++) {
        repository.simulateIncoming(_makeRemoteMessage('msg$i'));
      }
      await Future.delayed(const Duration(milliseconds: 40));

      expect(controller.state.messages.length, equals(200));
      expect(controller.state.messages.first.text, equals('msg0'));
      expect(controller.state.messages.last.text, equals('msg199'));
    });

    test('sendMessage also applies the 200-message cap', () async {
      // Fill up to 200 via incoming
      for (var i = 0; i < 200; i++) {
        repository.simulateIncoming(_makeRemoteMessage('remote$i'));
      }
      await Future.delayed(const Duration(milliseconds: 40));

      // Sending one more should trim the oldest
      await controller.sendMessage('local');

      expect(controller.state.messages.length, equals(200));
      expect(
        controller.state.messages.any((m) => m.text == 'remote0'),
        isFalse,
        reason: 'remote0 should have been evicted',
      );
      expect(controller.state.messages.last.text, equals('local'));
    });

    test('cap preserves correct chronological tail', () async {
      for (var i = 0; i < 210; i++) {
        repository.simulateIncoming(_makeRemoteMessage('msg$i'));
      }
      await Future.delayed(const Duration(milliseconds: 40));

      // Should retain msg10 … msg209 (last 200)
      expect(controller.state.messages.first.text, equals('msg10'));
      expect(controller.state.messages.last.text, equals('msg209'));
    });
  });
}

// ---------------------------------------------------------------------------
// Tracking repository that records sendReadReceipt calls
// ---------------------------------------------------------------------------

class _ReadReceiptCall {
  final String messageId;
  final int originalTimestamp;
  final Uint8List originalSenderId;
  _ReadReceiptCall({
    required this.messageId,
    required this.originalTimestamp,
    required this.originalSenderId,
  });
}

class _TrackingChatRepository implements ChatRepository {
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<ReceiptEvent> _receiptController =
      StreamController<ReceiptEvent>.broadcast();
  final List<String> sentMessages = [];
  final List<_ReadReceiptCall> readReceiptsSent = [];

  @override
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;

  @override
  Stream<ReceiptEvent> get onReceiptReceived => _receiptController.stream;

  @override
  Future<ChatMessage> sendMessage({
    required String text,
    required PeerId sender,
    String senderName = '',
  }) async {
    sentMessages.add(text);
    return ChatMessage(
      id: 'msg-${sentMessages.length}',
      sender: sender,
      senderName: senderName,
      text: text,
      timestamp: DateTime.now(),
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
    sentMessages.add(text);
    return ChatMessage(
      id: 'msg-${sentMessages.length}',
      sender: sender,
      text: text,
      timestamp: DateTime.now(),
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
    readReceiptsSent.add(_ReadReceiptCall(
      messageId: messageId,
      originalTimestamp: originalTimestamp,
      originalSenderId: originalSenderId,
    ));
  }

  void simulateIncoming(ChatMessage message) {
    _messageController.add(message);
  }

  @override
  void dispose() {
    _messageController.close();
    _receiptController.close();
  }
}
