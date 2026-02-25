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
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey) {
    if (groupKey == null) return null;
    final result = Uint8List(plaintext.length);
    for (var i = 0; i < plaintext.length; i++) {
      result[i] = plaintext[i] ^ groupKey[i % groupKey.length];
    }
    return result;
  }

  @override
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey) =>
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
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ReceiptService', () {
    late _MockTransport transport;
    late GroupManager groupManager;
    late ReceiptService service;
    final myPeerId = _makePeerId(0xAA);
    final remotePeerId = _makePeerId(0xBB);

    setUp(() {
      transport = _MockTransport();
      groupManager = GroupManager(
        cipher: _FakeGroupCipher(),
        groupStorage: GroupStorage(storage: _FakeSecureStorage()),
      );
      service = ReceiptService(
        transport: transport,
        myPeerId: myPeerId,
        groupManager: groupManager,
      );
      service.start();
    });

    tearDown(() {
      service.dispose();
      transport.dispose();
    });

    test('sendDeliveryReceipt broadcasts an ack packet', () async {
      await service.sendDeliveryReceipt(
        originalTimestamp: 1000,
        originalSenderId: remotePeerId.bytes,
      );

      expect(transport.broadcastedPackets, hasLength(1));
      final pkt = transport.broadcastedPackets.first;
      expect(pkt.type, equals(MessageType.ack));

      final decoded = BinaryProtocol.decodeReceiptPayload(pkt.payload);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.delivered));
      expect(decoded.originalTimestamp, equals(1000));
      expect(decoded.originalSenderId, equals(remotePeerId.bytes));
    });

    test('queueReadReceipt batches and sends after 2 seconds', () async {
      service.queueReadReceipt(
        messageId: 'msg1',
        originalTimestamp: 2000,
        originalSenderId: remotePeerId.bytes,
      );

      // Should not send immediately
      expect(transport.broadcastedPackets, isEmpty);

      // Wait for the 2-second batch timer
      await Future.delayed(const Duration(milliseconds: 2200));

      expect(transport.broadcastedPackets, hasLength(1));
      final pkt = transport.broadcastedPackets.first;
      final batch = BinaryProtocol.decodeBatchReceiptPayload(pkt.payload);
      expect(batch, isNotNull);
      expect(batch!.first.receiptType, equals(ReceiptType.read));
    });

    test('incoming receipt from remote peer emits ReceiptEvent', () async {
      final receiptPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 3000,
        originalSenderId: myPeerId.bytes,
      );

      final packet = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: receiptPayload,
      );

      final future = service.onReceiptReceived.first;
      transport.simulateIncomingPacket(packet);

      final event = await future;
      expect(event.receiptType, equals(ReceiptType.delivered));
      expect(event.fromPeer, equals(remotePeerId));

      // Format is now senderHex:timestamp (stable, independent of packet flags).
      final expectedId = '${HexUtils.encode(myPeerId.bytes)}:3000';
      expect(event.originalMessageId, equals(expectedId));
    });

    test('own receipts are skipped', () async {
      final receiptPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 4000,
        originalSenderId: remotePeerId.bytes,
      );

      final packet = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: myPeerId.bytes, // from ourselves
        payload: receiptPayload,
      );

      final completer = Completer<ReceiptEvent>();
      final sub = service.onReceiptReceived.listen(completer.complete);

      transport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(completer.isCompleted, isFalse);
      await sub.cancel();
    });

    test('group-encrypted receipt is sent when in group', () async {
      groupManager.createGroup('test-pass', groupName: 'Test');

      await service.sendDeliveryReceipt(
        originalTimestamp: 5000,
        originalSenderId: remotePeerId.bytes,
      );

      expect(transport.broadcastedPackets, hasLength(1));
      final pkt = transport.broadcastedPackets.first;

      // Verify it's an ack packet type (payload is encrypted)
      expect(pkt.type, equals(MessageType.ack));
    });

    test('group-encrypted incoming receipt is decrypted', () async {
      groupManager.createGroup('test-pass', groupName: 'Test');

      // Build encrypted receipt payload
      final plainPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.read,
        originalTimestamp: 6000,
        originalSenderId: myPeerId.bytes,
      );
      final encrypted = groupManager.encryptForGroup(plainPayload)!;

      final packet = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: encrypted,
      );

      final future = service.onReceiptReceived.first;
      transport.simulateIncomingPacket(packet);

      final event = await future;
      expect(event.receiptType, equals(ReceiptType.read));
      expect(event.fromPeer, equals(remotePeerId));
    });

    test('malformed receipt payload is ignored', () async {
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: Uint8List(10), // too short to be valid receipt
      );

      final completer = Completer<ReceiptEvent>();
      final sub = service.onReceiptReceived.listen(completer.complete);

      transport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(completer.isCompleted, isFalse);
      await sub.cancel();
    });

    test('multiple queued read receipts are all flushed in one batch', () async {
      final peerC = _makePeerId(0xCC);
      final peerD = _makePeerId(0xDD);

      service.queueReadReceipt(
        messageId: 'msg1',
        originalTimestamp: 1000,
        originalSenderId: remotePeerId.bytes,
      );
      service.queueReadReceipt(
        messageId: 'msg2',
        originalTimestamp: 2000,
        originalSenderId: peerC.bytes,
      );
      service.queueReadReceipt(
        messageId: 'msg3',
        originalTimestamp: 3000,
        originalSenderId: peerD.bytes,
      );

      expect(transport.broadcastedPackets, isEmpty);

      await Future.delayed(const Duration(milliseconds: 2200));

      // All three should be batched into a single packet
      expect(transport.broadcastedPackets, hasLength(1));
      final pkt = transport.broadcastedPackets.first;
      expect(pkt.type, equals(MessageType.ack));
      final batch = BinaryProtocol.decodeBatchReceiptPayload(pkt.payload);
      expect(batch, isNotNull);
      expect(batch, hasLength(3));
      for (final decoded in batch!) {
        expect(decoded.receiptType, equals(ReceiptType.read));
      }
    });

    test('queuing same messageId replaces previous entry', () async {
      service.queueReadReceipt(
        messageId: 'msg1',
        originalTimestamp: 1000,
        originalSenderId: remotePeerId.bytes,
      );
      // Re-queue the same messageId with different timestamp
      service.queueReadReceipt(
        messageId: 'msg1',
        originalTimestamp: 2000,
        originalSenderId: remotePeerId.bytes,
      );

      await Future.delayed(const Duration(milliseconds: 2200));

      // Should only send one batch packet (last wins for duplicate messageId)
      expect(transport.broadcastedPackets, hasLength(1));
      final batch = BinaryProtocol.decodeBatchReceiptPayload(
          transport.broadcastedPackets.first.payload);
      expect(batch, isNotNull);
      expect(batch, hasLength(1));
      expect(batch!.first.originalTimestamp, equals(2000));
    });

    test('can queue new read receipts after a flush completes', () async {
      service.queueReadReceipt(
        messageId: 'msg1',
        originalTimestamp: 1000,
        originalSenderId: remotePeerId.bytes,
      );

      // Wait for first flush
      await Future.delayed(const Duration(milliseconds: 2200));
      expect(transport.broadcastedPackets, hasLength(1));

      // Queue again
      transport.broadcastedPackets.clear();
      service.queueReadReceipt(
        messageId: 'msg2',
        originalTimestamp: 2000,
        originalSenderId: remotePeerId.bytes,
      );

      // Wait for second flush
      await Future.delayed(const Duration(milliseconds: 2200));
      expect(transport.broadcastedPackets, hasLength(1));

      final batch = BinaryProtocol.decodeBatchReceiptPayload(
          transport.broadcastedPackets.first.payload);
      expect(batch, isNotNull);
      expect(batch!.first.originalTimestamp, equals(2000));
    });

    test('non-ack packets are ignored by the service', () async {
      // Send a chat packet — service should not emit any receipt event
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: remotePeerId.bytes,
        payload: Uint8List.fromList([0x48, 0x69]), // "Hi"
      );

      final completer = Completer<ReceiptEvent>();
      final sub = service.onReceiptReceived.listen(completer.complete);

      transport.simulateIncomingPacket(chatPacket);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(completer.isCompleted, isFalse);
      await sub.cancel();
    });

    test('empty payload (0 bytes) is ignored', () async {
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: remotePeerId.bytes,
        payload: Uint8List(0),
      );

      final completer = Completer<ReceiptEvent>();
      final sub = service.onReceiptReceived.listen(completer.complete);

      transport.simulateIncomingPacket(packet);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(completer.isCompleted, isFalse);
      await sub.cancel();
    });

    test('receipt sourceId is correctly set to myPeerId', () async {
      await service.sendDeliveryReceipt(
        originalTimestamp: 7000,
        originalSenderId: remotePeerId.bytes,
      );

      final pkt = transport.broadcastedPackets.first;
      expect(pkt.sourceId, equals(myPeerId.bytes));
    });

    test('receipt event reconstructs correct originalMessageId format',
        () async {
      final receiptPayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.read,
        originalTimestamp: 8000,
        originalSenderId: remotePeerId.bytes,
      );

      final packet = BinaryProtocol.buildPacket(
        type: MessageType.ack,
        sourceId: _makePeerId(0xCC).bytes,
        payload: receiptPayload,
      );

      final future = service.onReceiptReceived.first;
      transport.simulateIncomingPacket(packet);
      final event = await future;

      // Format is now senderHex:timestamp (stable, independent of packet flags).
      final expectedId = '${HexUtils.encode(remotePeerId.bytes)}:8000';
      expect(event.originalMessageId, equals(expectedId));
      expect(event.receiptType, equals(ReceiptType.read));
      expect(event.fromPeer, equals(_makePeerId(0xCC)));
    });

    test('delivery receipt has correct sourceId in packet', () async {
      await service.sendDeliveryReceipt(
        originalTimestamp: 9000,
        originalSenderId: remotePeerId.bytes,
      );

      final pkt = transport.broadcastedPackets.first;
      // Packet sourceId should be our own peer ID
      expect(pkt.sourceId, equals(myPeerId.bytes));
      // Packet should be broadcast (destId all zeros)
      expect(pkt.isBroadcast, isTrue);
    });
  });
}
