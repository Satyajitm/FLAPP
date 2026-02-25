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
import 'package:fluxon_app/features/chat/chat_controller.dart';
import 'package:fluxon_app/features/chat/data/mesh_chat_repository.dart';
import 'package:fluxon_app/features/chat/message_model.dart';
import 'package:fluxon_app/shared/hex_utils.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class _MockTransport implements Transport {
  final StreamController<FluxonPacket> _packetController =
      StreamController<FluxonPacket>.broadcast();
  final List<FluxonPacket> broadcastedPackets = [];

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    broadcastedPackets.add(packet);
  }

  void simulateIncomingPacket(FluxonPacket packet) {
    _packetController.add(packet);
  }

  void dispose() => _packetController.close();

  @override
  Stream<List<PeerConnection>> get connectedPeers => const Stream.empty();
  @override
  bool get isRunning => true;
  @override
  Uint8List get myPeerId => Uint8List(32);
  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async => true;
  @override
  Future<void> startServices() async {}
  @override
  Future<void> stopServices() async {}
}

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
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey, {Uint8List? additionalData}) =>
      encrypt(data, groupKey);

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
  }) async => _store[key];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

// ---------------------------------------------------------------------------
// Integration tests: full receipt lifecycle
// ---------------------------------------------------------------------------

void main() {
  group('Receipt integration — full lifecycle (no group)', () {
    late _MockTransport transport;
    late ReceiptService receiptService;
    late MeshChatRepository repository;
    late ChatController controller;
    final myPeerId = _makePeerId(0xAA);
    final remotePeerId = _makePeerId(0xBB);

    setUp(() {
      transport = _MockTransport();
      final groupManager = GroupManager(
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
      controller = ChatController(
        repository: repository,
        myPeerId: myPeerId,
        getDisplayName: () => 'TestUser',
      );
    });

    tearDown(() {
      controller.dispose();
      receiptService.dispose();
      transport.dispose();
    });

    test('send message → receive delivery receipt → status becomes delivered',
        () async {
      // 1) Send a message
      await controller.sendMessage('hello world');
      expect(controller.state.messages, hasLength(1));
      final sentMsg = controller.state.messages.first;
      expect(sentMsg.status, equals(MessageStatus.sent));

      // 2) Simulate remote peer sending back a delivery receipt
      final receiptPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: sentMsg.timestamp.millisecondsSinceEpoch,
        originalSenderId: myPeerId.bytes,
      );
      final receiptPacket = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: receiptPayload,
      );
      transport.simulateIncomingPacket(receiptPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // 3) Message status should be updated
      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.delivered));
      expect(updated.deliveredTo, contains(remotePeerId));
    });

    test('send message → receive read receipt → status becomes read',
        () async {
      await controller.sendMessage('test read');
      final sentMsg = controller.state.messages.first;

      // Simulate read receipt from remote
      final receiptPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.read,
        originalTimestamp: sentMsg.timestamp.millisecondsSinceEpoch,
        originalSenderId: myPeerId.bytes,
      );
      final receiptPacket = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: receiptPayload,
      );
      transport.simulateIncomingPacket(receiptPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.read));
      expect(updated.readBy, contains(remotePeerId));
      expect(updated.deliveredTo, contains(remotePeerId));
    });

    test('delivery receipt then read receipt → progressive status upgrade',
        () async {
      await controller.sendMessage('test progressive');
      final sentMsg = controller.state.messages.first;
      final ts = sentMsg.timestamp.millisecondsSinceEpoch;

      // 1) Delivery receipt
      transport.simulateIncomingPacket(BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: BinaryProtocol.encodeReceiptPayload(
          receiptType: ReceiptType.delivered,
          originalTimestamp: ts,
          originalSenderId: myPeerId.bytes,
        ),
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(controller.state.messages.first.status,
          equals(MessageStatus.delivered));

      // 2) Read receipt
      transport.simulateIncomingPacket(BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: BinaryProtocol.encodeReceiptPayload(
          receiptType: ReceiptType.read,
          originalTimestamp: ts,
          originalSenderId: myPeerId.bytes,
        ),
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(
          controller.state.messages.first.status, equals(MessageStatus.read));
    });

    test('incoming message auto-triggers delivery receipt broadcast', () async {
      // Simulate a remote chat message arriving
      final chatPayload = BinaryProtocol.encodeChatPayload('hey there');
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: remotePeerId.bytes,
        payload: chatPayload,
      );

      transport.broadcastedPackets.clear();
      transport.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // Controller should have the incoming message
      expect(controller.state.messages, hasLength(1));
      expect(controller.state.messages.first.text, equals('hey there'));

      // ReceiptService should have broadcast a delivery receipt
      final ackPackets = transport.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(ackPackets, hasLength(1));

      final decoded =
          BinaryProtocol.decodeReceiptPayload(ackPackets.first.payload);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.delivered));
      expect(decoded.originalSenderId, equals(remotePeerId.bytes));
    });

    test('markMessagesAsRead triggers read receipt (batched)', () async {
      // Simulate remote message
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: remotePeerId.bytes,
        payload: BinaryProtocol.encodeChatPayload('read me'),
      );
      transport.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // Clear the delivery receipt that was auto-sent
      transport.broadcastedPackets.clear();

      // Mark as read
      controller.markMessagesAsRead(controller.state.messages);

      // Should not send immediately (batched)
      expect(
          transport.broadcastedPackets.where((p) => p.type == MessageType.ack),
          isEmpty);

      // Wait for 2-second batch flush
      await Future.delayed(const Duration(milliseconds: 2200));

      final readAcks = transport.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(readAcks, hasLength(1));

      final batch =
          BinaryProtocol.decodeBatchReceiptPayload(readAcks.first.payload);
      expect(batch, isNotNull);
      expect(batch!.first.receiptType, equals(ReceiptType.read));
    });

    test('receipts from multiple peers accumulate', () async {
      await controller.sendMessage('multi-peer test');
      final sentMsg = controller.state.messages.first;
      final ts = sentMsg.timestamp.millisecondsSinceEpoch;

      final peerB = _makePeerId(0xBB);
      final peerC = _makePeerId(0xCC);
      final peerD = _makePeerId(0xDD);

      for (final peer in [peerB, peerC, peerD]) {
        transport.simulateIncomingPacket(BinaryProtocol.buildPacket(
          type: MessageType.ack,
          sourceId: peer.bytes,
          payload: BinaryProtocol.encodeReceiptPayload(
            receiptType: ReceiptType.delivered,
            originalTimestamp: ts,
            originalSenderId: myPeerId.bytes,
          ),
        ));
      }

      await Future.delayed(const Duration(milliseconds: 50));

      final updated = controller.state.messages.first;
      expect(updated.deliveredTo, hasLength(3));
      expect(updated.deliveredTo, containsAll([peerB, peerC, peerD]));
      expect(updated.status, equals(MessageStatus.delivered));
    });

    test('receipt originalMessageId uses stable sender:timestamp format',
        () async {
      await controller.sendMessage('id-matching test');
      final sentMsg = controller.state.messages.first;

      // packetId (dedup key) includes flags: sourceIdHex:timestamp:type:flags
      final expectedPrefix = HexUtils.encode(myPeerId.bytes);
      expect(sentMsg.id, startsWith(expectedPrefix));
      expect(sentMsg.id, contains(':${MessageType.chat.value}:'));

      // Receipt-matching key is stable: senderHex:timestamp (no type/flags)
      final receiptKey =
          '${sentMsg.sender.hex}:${sentMsg.timestamp.millisecondsSinceEpoch}';
      expect(receiptKey, startsWith(expectedPrefix));
    });
  });

  group('Receipt integration — with group encryption', () {
    late _MockTransport transport;
    late GroupManager groupManager;
    late ReceiptService receiptService;
    late MeshChatRepository repository;
    late ChatController controller;
    final myPeerId = _makePeerId(0xAA);
    final remotePeerId = _makePeerId(0xBB);

    setUp(() {
      transport = _MockTransport();
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      groupManager.createGroup('shared-pass', groupName: 'TestGroup');
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
      controller = ChatController(
        repository: repository,
        myPeerId: myPeerId,
        getDisplayName: () => 'TestUser',
      );
    });

    tearDown(() {
      controller.dispose();
      receiptService.dispose();
      transport.dispose();
    });

    test('encrypted delivery receipt round-trip through controller', () async {
      await controller.sendMessage('encrypted msg');
      final sentMsg = controller.state.messages.first;
      final ts = sentMsg.timestamp.millisecondsSinceEpoch;

      // Build an encrypted delivery receipt (as the remote peer would send)
      final plainReceipt = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: ts,
        originalSenderId: myPeerId.bytes,
      );
      final encryptedReceipt = groupManager.encryptForGroup(plainReceipt)!;

      transport.simulateIncomingPacket(BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: encryptedReceipt,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.delivered));
      expect(updated.deliveredTo, contains(remotePeerId));
    });

    test('encrypted read receipt round-trip through controller', () async {
      await controller.sendMessage('encrypted msg 2');
      final sentMsg = controller.state.messages.first;
      final ts = sentMsg.timestamp.millisecondsSinceEpoch;

      final plainReceipt = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.read,
        originalTimestamp: ts,
        originalSenderId: myPeerId.bytes,
      );
      final encryptedReceipt = groupManager.encryptForGroup(plainReceipt)!;

      transport.simulateIncomingPacket(BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: encryptedReceipt,
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final updated = controller.state.messages.first;
      expect(updated.status, equals(MessageStatus.read));
      expect(updated.readBy, contains(remotePeerId));
    });

    test('auto delivery receipt is group-encrypted', () async {
      // Build an encrypted chat message from remote
      final chatPayload = BinaryProtocol.encodeChatPayload('group hello');
      final encryptedChat = groupManager.encryptForGroup(chatPayload)!;
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: remotePeerId.bytes,
        payload: encryptedChat,
      );

      transport.broadcastedPackets.clear();
      transport.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // The auto-sent delivery receipt should be encrypted (not decodable as plain)
      final ackPackets = transport.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(ackPackets, hasLength(1));

      // The key check is that the ack was sent
      expect(ackPackets.first.type, equals(MessageType.ack));

      // Decrypt and verify it's a valid delivery receipt
      final decrypted =
          groupManager.decryptFromGroup(ackPackets.first.payload);
      expect(decrypted, isNotNull);
      final decoded = BinaryProtocol.decodeReceiptPayload(decrypted!);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.delivered));
    });
  });

  group('Receipt integration — two simulated peers', () {
    test('peer A sends message, peer B auto-delivers, A sees delivered status',
        () async {
      // Set up Peer A
      final transportA = _MockTransport();
      final groupManagerA = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      final peerA = _makePeerId(0xAA);
      final receiptServiceA = ReceiptService(
        transport: transportA,
        myPeerId: peerA,
        groupManager: groupManagerA,
      );
      receiptServiceA.start();
      final repoA = MeshChatRepository(
        transport: transportA,
        myPeerId: peerA,
        groupManager: groupManagerA,
        receiptService: receiptServiceA,
      );
      final controllerA = ChatController(
        repository: repoA,
        myPeerId: peerA,
        getDisplayName: () => 'PeerA',
      );

      // Set up Peer B
      final transportB = _MockTransport();
      final groupManagerB = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      final peerB = _makePeerId(0xBB);
      final receiptServiceB = ReceiptService(
        transport: transportB,
        myPeerId: peerB,
        groupManager: groupManagerB,
      );
      receiptServiceB.start();
      final repoB = MeshChatRepository(
        transport: transportB,
        myPeerId: peerB,
        groupManager: groupManagerB,
        receiptService: receiptServiceB,
      );

      // 1) Peer A sends a message — capture the actual packet so timestamps match.
      await controllerA.sendMessage('hello B!');
      final chatPacket = transportA.broadcastedPackets
          .firstWhere((p) => p.type == MessageType.chat);

      // 2) Simulate the same packet arriving on Peer B's transport.
      transportB.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      // 3) Peer B should have auto-broadcast a delivery receipt
      final bAcks = transportB.broadcastedPackets
          .where((p) => p.type == MessageType.ack)
          .toList();
      expect(bAcks, hasLength(1));

      // 4) Simulate that receipt arriving on Peer A's transport
      // Reconstruct with B's sourceId
      final receiptFromB = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: peerB.bytes,
        payload: bAcks.first.payload,
      );
      transportA.simulateIncomingPacket(receiptFromB);
      await Future.delayed(const Duration(milliseconds: 50));

      // 5) Peer A's message should now be marked as delivered
      final updated = controllerA.state.messages.first;
      expect(updated.status, equals(MessageStatus.delivered));
      expect(updated.deliveredTo, contains(peerB));

      // Cleanup
      controllerA.dispose();
      receiptServiceA.dispose();
      receiptServiceB.dispose();
      repoB.dispose();
      transportA.dispose();
      transportB.dispose();
    });
  });
}
