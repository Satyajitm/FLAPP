import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/services/message_storage_service.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Test-friendly subclass that writes to a temp directory instead of
// the real getApplicationDocumentsDirectory().
// ---------------------------------------------------------------------------

class TestableStorageService extends MessageStorageService {
  final Directory tempDir;

  TestableStorageService(this.tempDir);

  @override
  Future<String> getDirectoryPath() async => tempDir.path;
}

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

ChatMessage _makeMessage(String text, {bool isLocal = false, int senderByte = 0xBB}) {
  return ChatMessage(
    id: 'msg-${text.hashCode}',
    sender: _makePeerId(senderByte),
    senderName: 'TestUser',
    text: text,
    timestamp: DateTime(2026, 2, 20, 12, 30, 0),
    isLocal: isLocal,
    status: isLocal ? MessageStatus.sent : MessageStatus.sent,
  );
}

void main() {
  group('ChatMessage serialization', () {
    test('toJson produces expected keys', () {
      final msg = _makeMessage('hello', isLocal: true);
      final json = msg.toJson();

      expect(json['id'], isA<String>());
      expect(json['sender'], isA<String>());
      expect(json['senderName'], equals('TestUser'));
      expect(json['text'], equals('hello'));
      expect(json['timestamp'], isA<String>());
      expect(json['isLocal'], isTrue);
      expect(json['status'], equals('sent'));
    });

    test('fromJson round-trips correctly', () {
      final original = _makeMessage('round-trip', isLocal: true, senderByte: 0xCC);
      final json = original.toJson();
      final restored = ChatMessage.fromJson(json);

      expect(restored.id, equals(original.id));
      expect(restored.sender, equals(original.sender));
      expect(restored.senderName, equals(original.senderName));
      expect(restored.text, equals(original.text));
      expect(restored.timestamp, equals(original.timestamp));
      expect(restored.isLocal, equals(original.isLocal));
      expect(restored.status, equals(original.status));
    });

    test('fromJson handles missing optional fields gracefully', () {
      final json = {
        'id': 'test-id',
        'sender': _makePeerId(0xAA).hex,
        'text': 'hi',
        'timestamp': DateTime.now().toIso8601String(),
      };

      final msg = ChatMessage.fromJson(json);
      expect(msg.senderName, equals(''));
      expect(msg.isLocal, isFalse);
      expect(msg.status, equals(MessageStatus.sent));
    });

    test('fromJson handles all MessageStatus values', () {
      for (final status in MessageStatus.values) {
        final json = {
          'id': 'id-${status.name}',
          'sender': _makePeerId(0xDD).hex,
          'text': 'status test',
          'timestamp': DateTime.now().toIso8601String(),
          'status': status.name,
        };
        final msg = ChatMessage.fromJson(json);
        expect(msg.status, equals(status));
      }
    });
  });

  group('MessageStorageService — per-group storage', () {
    late Directory tempDir;
    late TestableStorageService service;
    const groupA = 'group-alpha-001';
    const groupB = 'group-beta-002';

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fluxon_test_');
      service = TestableStorageService(tempDir);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('loadMessages returns empty list when no file exists', () async {
      final messages = await service.loadMessages(groupA);
      expect(messages, isEmpty);
    });

    test('saveMessages then loadMessages round-trips for a group', () async {
      final original = [
        _makeMessage('first', isLocal: true, senderByte: 0xAA),
        _makeMessage('second', isLocal: false, senderByte: 0xBB),
      ];

      await service.saveMessages(groupA, original);
      final loaded = await service.loadMessages(groupA);

      expect(loaded, hasLength(2));
      expect(loaded[0].text, equals('first'));
      expect(loaded[0].isLocal, isTrue);
      expect(loaded[1].text, equals('second'));
      expect(loaded[1].isLocal, isFalse);
    });

    test('different groups have independent message histories', () async {
      final messagesA = [_makeMessage('alpha msg', senderByte: 0xAA)];
      final messagesB = [_makeMessage('beta msg', senderByte: 0xBB)];

      await service.saveMessages(groupA, messagesA);
      await service.saveMessages(groupB, messagesB);

      final loadedA = await service.loadMessages(groupA);
      final loadedB = await service.loadMessages(groupB);

      expect(loadedA, hasLength(1));
      expect(loadedA[0].text, equals('alpha msg'));
      expect(loadedB, hasLength(1));
      expect(loadedB[0].text, equals('beta msg'));
    });

    test('deleteAllMessages only clears the targeted group', () async {
      await service.saveMessages(groupA, [_makeMessage('a')]);
      await service.saveMessages(groupB, [_makeMessage('b')]);

      await service.deleteAllMessages(groupA);

      final loadedA = await service.loadMessages(groupA);
      final loadedB = await service.loadMessages(groupB);

      expect(loadedA, isEmpty);
      expect(loadedB, hasLength(1));
      expect(loadedB[0].text, equals('b'));
    });

    test('deleteMessage removes only the targeted message', () async {
      final messages = [
        _makeMessage('keep me', senderByte: 0xAA),
        _makeMessage('delete me', senderByte: 0xBB),
        _makeMessage('keep me too', senderByte: 0xCC),
      ];
      await service.saveMessages(groupA, messages);

      await service.deleteMessage(groupA, messages[1].id, messages);
      final loaded = await service.loadMessages(groupA);

      expect(loaded, hasLength(2));
      expect(loaded.any((m) => m.text == 'delete me'), isFalse);
      expect(loaded[0].text, equals('keep me'));
      expect(loaded[1].text, equals('keep me too'));
    });

    test('loadMessages handles corrupt JSON gracefully', () async {
      final file = await service.getFileForGroup(groupA);
      await file.writeAsString('this is not json {{{');

      final messages = await service.loadMessages(groupA);
      expect(messages, isEmpty);
    });

    test('loadMessages handles empty file gracefully', () async {
      final file = await service.getFileForGroup(groupA);
      await file.writeAsString('');

      final messages = await service.loadMessages(groupA);
      expect(messages, isEmpty);
    });

    test('saving empty list creates valid JSON', () async {
      await service.saveMessages(groupA, []);
      final loaded = await service.loadMessages(groupA);
      expect(loaded, isEmpty);
    });

    test('group files use sanitized names', () async {
      // Group IDs with special chars should still work
      const weirdId = 'group/with:special<chars>';
      await service.saveMessages(weirdId, [_makeMessage('safe')]);
      final loaded = await service.loadMessages(weirdId);
      expect(loaded, hasLength(1));
      expect(loaded[0].text, equals('safe'));
    });
  });
}
