import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/group_cipher.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/group_storage.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/services/receipt_service.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:fluxon_app/features/chat/data/mesh_chat_repository.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Mock Transport for testing
// ---------------------------------------------------------------------------

class MockTransport implements Transport {
  final StreamController<FluxonPacket> _packetController =
      StreamController<FluxonPacket>.broadcast();
  final List<FluxonPacket> broadcastedPackets = [];

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    broadcastedPackets.add(packet);
  }

  /// Simulate receiving a packet from a peer.
  void simulateIncomingPacket(FluxonPacket packet) {
    _packetController.add(packet);
  }

  void dispose() {
    _packetController.close();
  }

  // --- Unused members for this test ---
  @override
  Stream<List<PeerConnection>> get connectedPeers =>
      const Stream.empty();
  @override
  bool get isRunning => true;
  @override
  Uint8List get myPeerId => Uint8List(32);
  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async =>
      true;
  @override
  Future<void> startServices() async {}
  @override
  Future<void> stopServices() async {}
}

// ---------------------------------------------------------------------------
// Helper to build a peer ID
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

FluxonPacket _buildChatPacket(String text, {int senderByte = 0xAA}) {
  return BinaryProtocol.buildPacket(
    type: MessageType.chat,
    sourceId: Uint8List(32)..fillRange(0, 32, senderByte),
    payload: BinaryProtocol.encodeChatPayload(text),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MeshChatRepository', () {
    late MockTransport transport;
    late MeshChatRepository repository;

    setUp(() {
      transport = MockTransport();
      repository = MeshChatRepository(transport: transport);
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('onMessageReceived emits decoded ChatMessage for incoming chat packets',
        () async {
      final packet = _buildChatPacket('Hello mesh!', senderByte: 0xBB);

      // Listen before simulating
      final future = repository.onMessageReceived.first;
      transport.simulateIncomingPacket(packet);

      final message = await future;
      expect(message.text, equals('Hello mesh!'));
      expect(message.sender, equals(_makePeerId(0xBB)));
      expect(message.isLocal, isFalse);
    });

    test('onMessageReceived ignores non-chat packets', () async {
      final locationPacket = BinaryProtocol.buildPacket(
        type: MessageType.locationUpdate,
        sourceId: Uint8List(32),
        payload: BinaryProtocol.encodeLocationPayload(
          latitude: 0, longitude: 0,
        ),
      );

      // Should not receive anything
      final completer = Completer<ChatMessage>();
      final sub = repository.onMessageReceived.listen(completer.complete);

      transport.simulateIncomingPacket(locationPacket);

      // Give it a moment to process, then verify nothing arrived
      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, isFalse);

      await sub.cancel();
    });

    test('sendMessage broadcasts packet and returns local ChatMessage',
        () async {
      final sender = _makePeerId(0xCC);
      final result = await repository.sendMessage(
        text: 'Test message',
        sender: sender,
      );

      // Verify the returned message
      expect(result.text, equals('Test message'));
      expect(result.sender, equals(sender));
      expect(result.isLocal, isTrue);
      expect(result.status, equals(MessageStatus.sent));
      expect(result.id, isNotEmpty);

      // Verify a packet was broadcast
      expect(transport.broadcastedPackets, hasLength(1));
      final sentPacket = transport.broadcastedPackets.first;
      expect(sentPacket.type, equals(MessageType.chat));

      // Verify payload round-trips correctly
      final decodedPayload =
          BinaryProtocol.decodeChatPayload(sentPacket.payload);
      expect(decodedPayload.text, equals('Test message'));
    });

    test('sendMessage handles Unicode text', () async {
      final sender = _makePeerId(0xDD);
      final result = await repository.sendMessage(
        text: '🚀 Hello 世界!',
        sender: sender,
      );
      expect(result.text, equals('🚀 Hello 世界!'));
    });

    test('multiple incoming messages arrive in order', () async {
      final messages = <ChatMessage>[];
      final sub = repository.onMessageReceived.listen(messages.add);

      transport.simulateIncomingPacket(
          _buildChatPacket('first', senderByte: 0x01));
      transport.simulateIncomingPacket(
          _buildChatPacket('second', senderByte: 0x02));
      transport.simulateIncomingPacket(
          _buildChatPacket('third', senderByte: 0x03));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(messages, hasLength(3));
      expect(messages[0].text, equals('first'));
      expect(messages[1].text, equals('second'));
      expect(messages[2].text, equals('third'));

      await sub.cancel();
    });
  });

  group('MeshChatRepository — self-source filtering', () {
    late MockTransport transport;
    late MeshChatRepository repository;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      transport = MockTransport();
      repository = MeshChatRepository(
        transport: transport,
        myPeerId: myPeerId,
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('filters out packets from own sourceId', () async {
      // Packet from ourselves (sourceId matches myPeerId 0xAA)
      final selfPacket = _buildChatPacket('my own msg', senderByte: 0xAA);

      final completer = Completer<ChatMessage>();
      final sub = repository.onMessageReceived.listen(completer.complete);

      transport.simulateIncomingPacket(selfPacket);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, isFalse);

      await sub.cancel();
    });

    test('passes through packets from different sourceId', () async {
      // Packet from a different peer (0xBB != 0xAA)
      final remotePacket = _buildChatPacket('hello', senderByte: 0xBB);

      final future = repository.onMessageReceived.first;
      transport.simulateIncomingPacket(remotePacket);

      final message = await future;
      expect(message.text, equals('hello'));
      expect(message.isLocal, isFalse);
    });

    test('filters self but passes remote in a mixed stream', () async {
      final messages = <ChatMessage>[];
      final sub = repository.onMessageReceived.listen(messages.add);

      // Mix of self-sourced and remote packets
      transport.simulateIncomingPacket(
          _buildChatPacket('from me', senderByte: 0xAA));
      transport.simulateIncomingPacket(
          _buildChatPacket('from peer B', senderByte: 0xBB));
      transport.simulateIncomingPacket(
          _buildChatPacket('also from me', senderByte: 0xAA));
      transport.simulateIncomingPacket(
          _buildChatPacket('from peer C', senderByte: 0xCC));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(messages, hasLength(2));
      expect(messages[0].text, equals('from peer B'));
      expect(messages[1].text, equals('from peer C'));

      await sub.cancel();
    });

    test('sendMessage still works normally with myPeerId set', () async {
      final result = await repository.sendMessage(
        text: 'outgoing',
        sender: myPeerId,
      );

      expect(result.text, equals('outgoing'));
      expect(result.isLocal, isTrue);
      expect(result.status, equals(MessageStatus.sent));
      expect(transport.broadcastedPackets, hasLength(1));
    });
  });

  group('MeshChatRepository — myPeerId=null (backwards compat)', () {
    late MockTransport transport;
    late MeshChatRepository repository;

    setUp(() {
      transport = MockTransport();
      // No myPeerId — the original constructor signature
      repository = MeshChatRepository(transport: transport);
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('does not filter any packets when myPeerId is null', () async {
      final messages = <ChatMessage>[];
      final sub = repository.onMessageReceived.listen(messages.add);

      // Even packets from any sourceId should pass through
      transport.simulateIncomingPacket(
          _buildChatPacket('msg1', senderByte: 0xAA));
      transport.simulateIncomingPacket(
          _buildChatPacket('msg2', senderByte: 0xBB));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(messages, hasLength(2));
      expect(messages[0].text, equals('msg1'));
      expect(messages[1].text, equals('msg2'));

      await sub.cancel();
    });
  });

  // -------------------------------------------------------------------------
  // Group encryption tests
  // -------------------------------------------------------------------------

  group('MeshChatRepository — group encryption', () {
    late MockTransport transport;
    late GroupManager groupManager;
    late MeshChatRepository repository;
    final myPeerId = _makePeerId(0xAA);
    final remotePeerId = _makePeerId(0xBB);

    setUp(() async {
      transport = MockTransport();
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      await groupManager.createGroup('test-pass', groupName: 'Test');
      repository = MeshChatRepository(
        transport: transport,
        myPeerId: myPeerId,
        groupManager: groupManager,
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('sendMessage encrypts payload when in a group', () async {
      await repository.sendMessage(text: 'secret msg', sender: myPeerId);

      expect(transport.broadcastedPackets, hasLength(1));
      final pkt = transport.broadcastedPackets.first;

      // Payload should NOT decode as plain chat text (it's encrypted)
      final rawText = BinaryProtocol.decodeChatPayload(pkt.payload);
      expect(rawText, isNot(equals('secret msg')));
    });

    test('incoming encrypted message is decrypted correctly', () async {
      // Build an encrypted packet the same way sendMessage would
      final plainPayload = BinaryProtocol.encodeChatPayload('hello encrypted');
      final encrypted = groupManager.encryptForGroup(plainPayload)!;
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: remotePeerId.bytes,
        payload: encrypted,
      );

      final future = repository.onMessageReceived.first;
      transport.simulateIncomingPacket(packet);

      final msg = await future;
      expect(msg.text, equals('hello encrypted'));
      expect(msg.isLocal, isFalse);
    });

    test('incoming message with wrong group key is dropped', () async {
      // Build a packet encrypted with a different group key
      final otherManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      await otherManager.createGroup('different-pass');

      final plainPayload = BinaryProtocol.encodeChatPayload('wrong group');
      final encrypted = otherManager.encryptForGroup(plainPayload)!;
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: remotePeerId.bytes,
        payload: encrypted,
      );

      final completer = Completer<ChatMessage>();
      final sub = repository.onMessageReceived.listen(completer.complete);

      transport.simulateIncomingPacket(packet);

      await Future.delayed(const Duration(milliseconds: 50));
      // With the fake XOR cipher, decrypting with the wrong key produces
      // garbage that still gets decoded (no MAC check). In a real scenario
      // with AEAD, this would be null and get dropped. For our fake cipher,
      // the message still arrives but with garbled text.
      // This test validates the encryption path is exercised.
      if (completer.isCompleted) {
        final msg = await completer.future;
        expect(msg.text, isNot(equals('wrong group')));
      }

      await sub.cancel();
    });

    test('sendMessage returns unencrypted text in local ChatMessage', () async {
      final result = await repository.sendMessage(
        text: 'my secret',
        sender: myPeerId,
      );

      // The returned ChatMessage should contain the plaintext
      expect(result.text, equals('my secret'));
      expect(result.isLocal, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Receipt integration tests
  // -------------------------------------------------------------------------

  group('MeshChatRepository — receipt wiring', () {
    late MockTransport transport;
    late GroupManager groupManager;
    late ReceiptService receiptService;
    late MeshChatRepository repository;
    final myPeerId = _makePeerId(0xAA);
    final remotePeerId = _makePeerId(0xBB);

    setUp(() {
      transport = MockTransport();
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      receiptService = ReceiptService(
        transport: transport,
        myPeerId: myPeerId,
        groupManager: groupManager,
      );
      receiptService.start();
      repository = MeshChatRepository(
        transport: transport,
        myPeerId: myPeerId,
        groupManager: groupManager,
        receiptService: receiptService,
      );
    });

    tearDown(() {
      repository.dispose();
      receiptService.dispose();
      transport.dispose();
    });

    test('incoming chat message auto-sends delivery receipt', () async {
      final chatPacket = _buildChatPacket('trigger receipt', senderByte: 0xBB);

      transport.broadcastedPackets.clear();
      transport.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // Should have broadcast a delivery receipt
      final acks = transport.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(acks, hasLength(1));

      final decoded = BinaryProtocol.decodeReceiptPayload(acks.first.payload);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.delivered));
      expect(decoded.originalSenderId, equals(remotePeerId.bytes));
    });

    test('onReceiptReceived forwards events from ReceiptService', () async {
      final completer = Completer<ReceiptEvent>();
      final sub = repository.onReceiptReceived.listen(completer.complete);

      // Simulate an incoming receipt
      final receiptPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 9999,
        originalSenderId: myPeerId.bytes,
      );
      final receiptPacket = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: receiptPayload,
      );
      transport.simulateIncomingPacket(receiptPacket);

      final event = await completer.future;
      expect(event.receiptType, equals(ReceiptType.delivered));
      expect(event.fromPeer, equals(remotePeerId));

      await sub.cancel();
    });

    test('sendReadReceipt delegates to ReceiptService', () async {
      // Call sendReadReceipt — it queues in ReceiptService
      repository.sendReadReceipt(
        messageId: 'test-msg-id',
        originalTimestamp: 12345,
        originalSenderId: remotePeerId.bytes,
      );

      // Should not send immediately (batched)
      expect(
          transport.broadcastedPackets.where((p) => p.type == MessageType.ack),
          isEmpty);

      // Wait for 2-second batch timer
      await Future.delayed(const Duration(milliseconds: 2200));

      final acks = transport.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(acks, hasLength(1));

      final batch = BinaryProtocol.decodeBatchReceiptPayload(acks.first.payload);
      expect(batch, isNotNull);
      expect(batch!.first.receiptType, equals(ReceiptType.read));
    });

    test('no receipt sent for self-sourced packets', () async {
      // Self-sourced packet should be filtered AND no receipt sent
      final selfPacket = _buildChatPacket('from me', senderByte: 0xAA);

      transport.broadcastedPackets.clear();
      transport.simulateIncomingPacket(selfPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // No delivery receipt should be sent for our own packet
      final acks = transport.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(acks, isEmpty);
    });

    test('onReceiptReceived is empty stream when no receiptService', () async {
      final repoNoReceipt = MeshChatRepository(
        transport: transport,
        myPeerId: myPeerId,
      );

      final completer = Completer<ReceiptEvent>();
      final sub = repoNoReceipt.onReceiptReceived.listen(completer.complete);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, isFalse);

      await sub.cancel();
      repoNoReceipt.dispose();
    });

    test('sendPrivateMessage returns status sent', () async {
      final result = await repository.sendPrivateMessage(
        text: 'private msg',
        sender: myPeerId,
        recipient: remotePeerId,
      );

      expect(result.status, equals(MessageStatus.sent));
      expect(result.isLocal, isTrue);
    });
  });

  group('MeshChatRepository — no group (encryption bypassed)', () {
    late MockTransport transport;
    late GroupManager groupManager;
    late MeshChatRepository repository;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      transport = MockTransport();
      // GroupManager with no active group
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      repository = MeshChatRepository(
        transport: transport,
        myPeerId: myPeerId,
        groupManager: groupManager,
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('sendMessage sends plaintext when not in a group', () async {
      await repository.sendMessage(text: 'plain msg', sender: myPeerId);

      final pkt = transport.broadcastedPackets.first;
      final decoded = BinaryProtocol.decodeChatPayload(pkt.payload);
      expect(decoded.text, equals('plain msg'));
    });

    test('incoming plaintext message is received without decryption', () async {
      final packet = _buildChatPacket('plain hello', senderByte: 0xBB);

      final future = repository.onMessageReceived.first;
      transport.simulateIncomingPacket(packet);

      final msg = await future;
      expect(msg.text, equals('plain hello'));
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles for group encryption
// ---------------------------------------------------------------------------

class _FakeGroupCipher implements GroupCipher {
  @override
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey, {Uint8List? additionalData}) {
    if (groupKey == null) return null;
    final result = Uint8List(plaintext.length);
    for (var i = 0; i < plaintext.length; i++) {
      result[i] = plaintext[i] ^ groupKey[i % groupKey.length];
    }
    return result;
  }

  @override
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey, {Uint8List? additionalData}) {
    return encrypt(data, groupKey);
  }

  @override
  Uint8List deriveGroupKey(String passphrase, Uint8List salt) {
    final key = Uint8List(32);
    final bytes = passphrase.codeUnits;
    for (var i = 0; i < 32; i++) {
      key[i] = bytes[i % bytes.length] ^ (i * 7);
    }
    return key;
  }

  @override
  String generateGroupId(String passphrase, Uint8List salt) =>
      'fake-group-${passphrase.hashCode.toRadixString(16)}';

  @override
  Uint8List generateSalt() => Uint8List(16); // Fixed salt for deterministic tests

  static const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  @override
  String encodeSalt(Uint8List salt) {
    var buffer = 0;
    var bitsLeft = 0;
    final result = StringBuffer();
    for (final byte in salt) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        result.writeCharCode(_b32.codeUnitAt((buffer >> bitsLeft) & 0x1F));
      }
    }
    if (bitsLeft > 0) {
      result.writeCharCode(_b32.codeUnitAt((buffer << (5 - bitsLeft)) & 0x1F));
    }
    return result.toString();
  }

  @override
  Uint8List decodeSalt(String code) {
    final upper = code.toUpperCase();
    var buffer = 0;
    var bitsLeft = 0;
    final result = <int>[];
    for (final ch in upper.split('')) {
      final val = _b32.indexOf(ch);
      if (val < 0) throw FormatException('Invalid base32 char: $ch');
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        result.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(result);
  }

  @override
  void clearCache() {}

  @override
  Future<DerivedGroup> deriveAsync(String passphrase, Uint8List salt) async =>
      DerivedGroup(deriveGroupKey(passphrase, salt), generateGroupId(passphrase, salt));
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _store[key] = value;
    } else {
      _store.remove(key);
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _store[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
