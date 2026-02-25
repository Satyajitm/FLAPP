import 'dart:async';
import 'dart:typed_data';
import '../identity/group_manager.dart';
import '../identity/peer_id.dart';
import '../protocol/binary_protocol.dart';
import '../protocol/message_types.dart';
import '../protocol/packet.dart';
import '../transport/transport.dart';
import '../../shared/hex_utils.dart';

/// Receipt event emitted when an ack packet is received.
class ReceiptEvent {
  final String originalMessageId;
  final int receiptType;
  final PeerId fromPeer;

  const ReceiptEvent({
    required this.originalMessageId,
    required this.receiptType,
    required this.fromPeer,
  });
}

/// Manages sending and receiving delivery/read receipts.
///
/// Receipt lifecycle:
/// 1. On receiving a chat message → automatically send delivery receipt
/// 2. When chat screen is open and message is visible → send read receipt
/// 3. On receiving a receipt → emit event via [onReceiptReceived]
class ReceiptService {
  final Transport _transport;
  final PeerId _myPeerId;
  final GroupManager _groupManager;

  final StreamController<ReceiptEvent> _receiptController =
      StreamController<ReceiptEvent>.broadcast();

  StreamSubscription? _receiptSub;
  Timer? _readBatchTimer;
  final Map<String, _OriginalMessageRef> _pendingReadReceipts = {};
  bool _isDisposed = false;

  ReceiptService({
    required Transport transport,
    required PeerId myPeerId,
    required GroupManager groupManager,
  })  : _transport = transport,
        _myPeerId = myPeerId,
        _groupManager = groupManager;

  /// Stream of receipt events for messages we sent.
  Stream<ReceiptEvent> get onReceiptReceived => _receiptController.stream;

  /// Start listening for incoming receipt packets.
  void start() {
    _receiptSub = _transport.onPacketReceived
        .where((p) => p.type == MessageType.ack)
        .listen(_handleIncomingReceipt);
  }

  /// Send a delivery receipt for a received message.
  Future<void> sendDeliveryReceipt({
    required int originalTimestamp,
    required Uint8List originalSenderId,
  }) async {
    await _sendReceipt(
      receiptType: ReceiptType.delivered,
      originalTimestamp: originalTimestamp,
      originalSenderId: originalSenderId,
    );
  }

  /// Queue a read receipt (batched, sent every 2 seconds).
  void queueReadReceipt({
    required String messageId,
    required int originalTimestamp,
    required Uint8List originalSenderId,
  }) {
    _pendingReadReceipts[messageId] = _OriginalMessageRef(
      timestamp: originalTimestamp,
      senderId: originalSenderId,
    );
    _readBatchTimer ??= Timer(const Duration(seconds: 2), _flushReadReceipts);
  }

  Future<void> _flushReadReceipts() async {
    _readBatchTimer = null;
    if (_isDisposed || _pendingReadReceipts.isEmpty) return;

    final receipts = _pendingReadReceipts.values
        .map((ref) => ReceiptPayload(
              receiptType: ReceiptType.read,
              originalTimestamp: ref.timestamp,
              originalSenderId: ref.senderId,
            ))
        .toList();
    _pendingReadReceipts.clear();

    // Send all pending read receipts as a single BLE packet.
    await _sendBatchReceipts(receipts);
  }

  Future<void> _sendBatchReceipts(List<ReceiptPayload> receipts) async {
    var payload = BinaryProtocol.encodeBatchReceiptPayload(receipts);

    if (_groupManager.isInGroup) {
      final encrypted = _groupManager.encryptForGroup(payload);
      if (encrypted != null) payload = encrypted;
    }

    final packet = BinaryProtocol.buildPacket(
      type: MessageType.ack,
      sourceId: _myPeerId.bytes,
      payload: payload,
    );

    await _transport.broadcastPacket(packet);
  }

  Future<void> _sendReceipt({
    required int receiptType,
    required int originalTimestamp,
    required Uint8List originalSenderId,
  }) async {
    var payload = BinaryProtocol.encodeReceiptPayload(
      receiptType: receiptType,
      originalTimestamp: originalTimestamp,
      originalSenderId: originalSenderId,
    );

    // Group-encrypt if in a group
    if (_groupManager.isInGroup) {
      final encrypted = _groupManager.encryptForGroup(payload);
      if (encrypted != null) payload = encrypted;
    }

    final packet = BinaryProtocol.buildPacket(
      type: MessageType.ack,
      sourceId: _myPeerId.bytes,
      payload: payload,
    );

    await _transport.broadcastPacket(packet);
  }

  void _handleIncomingReceipt(FluxonPacket packet) {
    final fromPeer = PeerId(packet.sourceId);
    if (fromPeer == _myPeerId) return; // Skip own receipts

    Uint8List payload = packet.payload;
    if (_groupManager.isInGroup) {
      final decrypted = _groupManager.decryptFromGroup(payload);
      if (decrypted == null) return;
      payload = decrypted;
    }

    // Try batch format first, then fall back to single-receipt format.
    final batch = BinaryProtocol.decodeBatchReceiptPayload(payload);
    if (batch != null) {
      for (final receipt in batch) {
        _emitReceiptEvent(receipt, fromPeer);
      }
      return;
    }

    final single = BinaryProtocol.decodeReceiptPayload(payload);
    if (single != null) _emitReceiptEvent(single, fromPeer);
  }

  void _emitReceiptEvent(ReceiptPayload receipt, PeerId fromPeer) {
    final srcHex = HexUtils.encode(receipt.originalSenderId);
    // Use sender:timestamp as stable receipt-matching key (independent of
    // per-packet random flags introduced by MED-1).
    final originalMessageId = '$srcHex:${receipt.originalTimestamp}';
    _receiptController.add(ReceiptEvent(
      originalMessageId: originalMessageId,
      receiptType: receipt.receiptType,
      fromPeer: fromPeer,
    ));
  }

  void dispose() {
    _isDisposed = true;
    _receiptSub?.cancel();
    _readBatchTimer?.cancel();
    _receiptController.close();
  }
}

class _OriginalMessageRef {
  final int timestamp;
  final Uint8List senderId;
  _OriginalMessageRef({required this.timestamp, required this.senderId});
}
