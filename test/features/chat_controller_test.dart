import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/features/chat/chat_controller.dart';
import 'package:fluxon_app/features/chat/data/chat_repository.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Fake ChatRepository for testing the Controller in isolation
// ---------------------------------------------------------------------------

class FakeChatRepository implements ChatRepository {
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final List<String> sentMessages = [];
  bool shouldFailOnSend = false;

  @override
  Stream<ChatMessage> get onMessageReceived => _messageController.stream;

  @override
  Future<ChatMessage> sendMessage({
    required String text,
    required PeerId sender,
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
      isDelivered: true,
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
      isDelivered: true,
    );
  }

  /// Simulate an incoming message from a remote peer.
  void simulateIncoming(ChatMessage message) {
    _messageController.add(message);
  }

  @override
  void dispose() {
    _messageController.close();
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

    test('selectPeer sets selectedPeer for private messaging', () {
      final peer = _makePeerId(0xCC);
      controller.selectPeer(peer);
      expect(controller.state.selectedPeer, equals(peer));
    });

    test('selectPeer(null) clears selectedPeer back to broadcast mode', () {
      final peer = _makePeerId(0xCC);

      // Enter private message mode
      controller.selectPeer(peer);
      expect(controller.state.selectedPeer, equals(peer));

      // Exit private message mode
      controller.selectPeer(null);
      expect(controller.state.selectedPeer, isNull);
    });

    test('copyWith preserves selectedPeer when not passed', () {
      final peer = _makePeerId(0xDD);
      controller.selectPeer(peer);

      // copyWith without selectedPeer should preserve it
      final newState = controller.state.copyWith(isSending: true);
      expect(newState.selectedPeer, equals(peer));
      expect(newState.isSending, isTrue);
    });
  });
}
