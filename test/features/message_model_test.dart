import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

ChatMessage _makeMessage({
  String id = 'msg-1',
  int senderByte = 0xAA,
  String text = 'hello',
  bool isLocal = true,
  MessageStatus status = MessageStatus.sent,
  Set<PeerId> deliveredTo = const {},
  Set<PeerId> readBy = const {},
}) {
  return ChatMessage(
    id: id,
    sender: _makePeerId(senderByte),
    text: text,
    timestamp: DateTime(2025, 1, 1),
    isLocal: isLocal,
    status: status,
    deliveredTo: deliveredTo,
    readBy: readBy,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MessageStatus enum', () {
    test('has three values in correct order', () {
      expect(MessageStatus.values, hasLength(3));
      expect(MessageStatus.values[0], MessageStatus.sent);
      expect(MessageStatus.values[1], MessageStatus.delivered);
      expect(MessageStatus.values[2], MessageStatus.read);
    });
  });

  group('ChatMessage — default values', () {
    test('status defaults to sent', () {
      final msg = ChatMessage(
        id: 'id',
        sender: _makePeerId(0x01),
        text: 'hi',
        timestamp: DateTime.now(),
      );
      expect(msg.status, equals(MessageStatus.sent));
    });

    test('deliveredTo defaults to empty set', () {
      final msg = _makeMessage();
      expect(msg.deliveredTo, isEmpty);
    });

    test('readBy defaults to empty set', () {
      final msg = _makeMessage();
      expect(msg.readBy, isEmpty);
    });

    test('isLocal defaults to false', () {
      final msg = ChatMessage(
        id: 'id',
        sender: _makePeerId(0x01),
        text: 'hi',
        timestamp: DateTime.now(),
      );
      expect(msg.isLocal, isFalse);
    });

    test('senderName defaults to empty string', () {
      final msg = ChatMessage(
        id: 'id',
        sender: _makePeerId(0x01),
        text: 'hi',
        timestamp: DateTime.now(),
      );
      expect(msg.senderName, isEmpty);
    });
  });

  group('ChatMessage — isDelivered backward-compat getter', () {
    test('isDelivered is false when status is sent', () {
      final msg = _makeMessage(status: MessageStatus.sent);
      expect(msg.isDelivered, isFalse);
    });

    test('isDelivered is true when status is delivered', () {
      final msg = _makeMessage(status: MessageStatus.delivered);
      expect(msg.isDelivered, isTrue);
    });

    test('isDelivered is true when status is read', () {
      final msg = _makeMessage(status: MessageStatus.read);
      expect(msg.isDelivered, isTrue);
    });
  });

  group('ChatMessage — copyWith', () {
    test('copyWith with no arguments returns identical values', () {
      final peerA = _makePeerId(0xAA);
      final peerB = _makePeerId(0xBB);
      final original = _makeMessage(
        status: MessageStatus.delivered,
        deliveredTo: {peerA},
        readBy: {peerB},
      );

      final copy = original.copyWith();
      expect(copy.id, equals(original.id));
      expect(copy.sender, equals(original.sender));
      expect(copy.senderName, equals(original.senderName));
      expect(copy.text, equals(original.text));
      expect(copy.timestamp, equals(original.timestamp));
      expect(copy.isLocal, equals(original.isLocal));
      expect(copy.status, equals(original.status));
      expect(copy.deliveredTo, equals(original.deliveredTo));
      expect(copy.readBy, equals(original.readBy));
    });

    test('copyWith updates status only', () {
      final original = _makeMessage(status: MessageStatus.sent);
      final copy = original.copyWith(status: MessageStatus.delivered);

      expect(copy.status, equals(MessageStatus.delivered));
      expect(copy.text, equals(original.text));
      expect(copy.id, equals(original.id));
    });

    test('copyWith updates deliveredTo only', () {
      final peer = _makePeerId(0xBB);
      final original = _makeMessage();
      final copy = original.copyWith(deliveredTo: {peer});

      expect(copy.deliveredTo, contains(peer));
      expect(copy.status, equals(MessageStatus.sent)); // unchanged
    });

    test('copyWith updates readBy only', () {
      final peer = _makePeerId(0xCC);
      final original = _makeMessage();
      final copy = original.copyWith(readBy: {peer});

      expect(copy.readBy, contains(peer));
      expect(copy.deliveredTo, isEmpty); // unchanged
    });

    test('copyWith updates all fields at once', () {
      final peerA = _makePeerId(0xAA);
      final peerB = _makePeerId(0xBB);
      final original = _makeMessage();
      final copy = original.copyWith(
        status: MessageStatus.read,
        deliveredTo: {peerA, peerB},
        readBy: {peerB},
      );

      expect(copy.status, equals(MessageStatus.read));
      expect(copy.deliveredTo, hasLength(2));
      expect(copy.readBy, hasLength(1));
    });

    test('copyWith preserves immutable fields (id, sender, text, etc.)', () {
      final original = _makeMessage(
        id: 'unique-id',
        senderByte: 0xDD,
        text: 'immutable text',
        isLocal: true,
      );
      final copy = original.copyWith(status: MessageStatus.read);

      expect(copy.id, equals('unique-id'));
      expect(copy.sender, equals(_makePeerId(0xDD)));
      expect(copy.text, equals('immutable text'));
      expect(copy.isLocal, isTrue);
    });
  });

  group('ChatMessage — deliveredTo and readBy sets', () {
    test('deliveredTo set can hold multiple peers', () {
      final peers = {_makePeerId(0x01), _makePeerId(0x02), _makePeerId(0x03)};
      final msg = _makeMessage(deliveredTo: peers);
      expect(msg.deliveredTo, hasLength(3));
    });

    test('readBy set deduplicates same peer', () {
      final peer = _makePeerId(0xAA);
      final msg = _makeMessage(readBy: {peer, peer});
      expect(msg.readBy, hasLength(1));
    });

    test('copyWith can grow deliveredTo set', () {
      final peerA = _makePeerId(0xAA);
      final peerB = _makePeerId(0xBB);
      final msg = _makeMessage(deliveredTo: {peerA});
      final updated = msg.copyWith(deliveredTo: {...msg.deliveredTo, peerB});
      expect(updated.deliveredTo, containsAll([peerA, peerB]));
    });
  });
}
