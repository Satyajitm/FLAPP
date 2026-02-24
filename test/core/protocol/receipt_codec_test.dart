import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/packet.dart';

void main() {
  group('Receipt codec — encodeReceiptPayload / decodeReceiptPayload', () {
    test('round-trip delivery receipt', () {
      final senderId = Uint8List(32)..fillRange(0, 32, 0xAA);
      const timestamp = 1708396800000;

      final encoded = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: timestamp,
        originalSenderId: senderId,
      );

      expect(encoded.length, equals(41));

      final decoded = BinaryProtocol.decodeReceiptPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.delivered));
      expect(decoded.originalTimestamp, equals(timestamp));
      expect(decoded.originalSenderId, equals(senderId));
    });

    test('round-trip read receipt', () {
      final senderId = Uint8List(32)..fillRange(0, 32, 0xBB);
      const timestamp = 1708396900000;

      final encoded = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.read,
        originalTimestamp: timestamp,
        originalSenderId: senderId,
      );

      final decoded = BinaryProtocol.decodeReceiptPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.read));
      expect(decoded.originalTimestamp, equals(timestamp));
      expect(decoded.originalSenderId, equals(senderId));
    });

    test('decode returns null for payload shorter than 41 bytes', () {
      final shortData = Uint8List(40);
      expect(BinaryProtocol.decodeReceiptPayload(shortData), isNull);
    });

    test('decode returns null for empty payload', () {
      expect(BinaryProtocol.decodeReceiptPayload(Uint8List(0)), isNull);
    });

    test('decode handles payload longer than 41 bytes (ignores extra)', () {
      final senderId = Uint8List(32)..fillRange(0, 32, 0xCC);
      const timestamp = 1708397000000;

      final encoded = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: timestamp,
        originalSenderId: senderId,
      );

      // Append extra bytes
      final extended = Uint8List(encoded.length + 10);
      extended.setRange(0, encoded.length, encoded);

      final decoded = BinaryProtocol.decodeReceiptPayload(extended);
      expect(decoded, isNotNull);
      expect(decoded!.receiptType, equals(ReceiptType.delivered));
      expect(decoded.originalTimestamp, equals(timestamp));
    });

    test('different sender IDs produce different encoded payloads', () {
      final senderA = Uint8List(32)..fillRange(0, 32, 0xAA);
      final senderB = Uint8List(32)..fillRange(0, 32, 0xBB);

      final encodedA = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 1000,
        originalSenderId: senderA,
      );
      final encodedB = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 1000,
        originalSenderId: senderB,
      );

      expect(encodedA, isNot(equals(encodedB)));
    });

    test('different receipt types produce different first byte', () {
      final senderId = Uint8List(32);

      final delivered = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 1000,
        originalSenderId: senderId,
      );
      final read = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.read,
        originalTimestamp: 1000,
        originalSenderId: senderId,
      );

      expect(delivered[0], equals(0x01));
      expect(read[0], equals(0x02));
    });
  });

  // ---------------------------------------------------------------------------
  // Batch receipt codec tests
  // ---------------------------------------------------------------------------

  group('Batch receipt codec — encodeBatchReceiptPayload / decodeBatchReceiptPayload', () {
    ReceiptPayload _makeReceipt(int senderFill, int timestamp, int type) =>
        ReceiptPayload(
          receiptType: type,
          originalTimestamp: timestamp,
          originalSenderId: Uint8List(32)..fillRange(0, 32, senderFill),
        );

    test('round-trip with a single receipt', () {
      final receipt = _makeReceipt(0xAA, 1708396800000, ReceiptType.read);
      final encoded = BinaryProtocol.encodeBatchReceiptPayload([receipt]);

      expect(encoded[0], equals(0xFF)); // sentinel
      expect(encoded[1], equals(1));    // count

      final decoded = BinaryProtocol.decodeBatchReceiptPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded, hasLength(1));
      expect(decoded![0].receiptType, equals(ReceiptType.read));
      expect(decoded[0].originalTimestamp, equals(1708396800000));
      expect(decoded[0].originalSenderId, equals(Uint8List(32)..fillRange(0, 32, 0xAA)));
    });

    test('round-trip with three receipts preserves order and values', () {
      final receipts = [
        _makeReceipt(0x01, 1000, ReceiptType.delivered),
        _makeReceipt(0x02, 2000, ReceiptType.read),
        _makeReceipt(0x03, 3000, ReceiptType.delivered),
      ];
      final encoded = BinaryProtocol.encodeBatchReceiptPayload(receipts);
      expect(encoded[1], equals(3)); // count

      final decoded = BinaryProtocol.decodeBatchReceiptPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(decoded![i].originalTimestamp, equals(receipts[i].originalTimestamp));
        expect(decoded[i].receiptType, equals(receipts[i].receiptType));
        expect(decoded[i].originalSenderId, equals(receipts[i].originalSenderId));
      }
    });

    test('empty list encodes and decodes to empty list', () {
      final encoded = BinaryProtocol.encodeBatchReceiptPayload([]);
      expect(encoded[0], equals(0xFF));
      expect(encoded[1], equals(0));
      expect(encoded.length, equals(2));

      final decoded = BinaryProtocol.decodeBatchReceiptPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded, isEmpty);
    });

    test('encoded size is exactly 2 + count * 41 bytes', () {
      for (var n = 0; n <= 5; n++) {
        final receipts = List.generate(
          n,
          (i) => _makeReceipt(i, i * 1000, ReceiptType.read),
        );
        final encoded = BinaryProtocol.encodeBatchReceiptPayload(receipts);
        expect(encoded.length, equals(2 + n * 41),
            reason: 'size should be 2 + $n * 41 for $n receipts');
      }
    });

    test('list clamped at maxBatchReceiptCount — excess receipts are silently dropped', () {
      // Send more receipts than the cap (11) to verify clamping.
      final overLimit = BinaryProtocol.maxBatchReceiptCount + 10;
      final receipts = List.generate(
        overLimit,
        (i) => _makeReceipt(i & 0xFF, i * 1000, ReceiptType.read),
      );
      final encoded = BinaryProtocol.encodeBatchReceiptPayload(receipts);
      // count byte must equal the cap, not the input length
      expect(encoded[1], equals(BinaryProtocol.maxBatchReceiptCount));

      final decoded = BinaryProtocol.decodeBatchReceiptPayload(encoded);
      expect(decoded, hasLength(BinaryProtocol.maxBatchReceiptCount));

      // Verify the encoded payload fits within the 512-byte packet limit.
      expect(encoded.length, lessThanOrEqualTo(FluxonPacket.maxPayloadSize));
    });

    test('decodeBatchReceiptPayload returns null for non-batch payload (no sentinel)', () {
      // A regular single receipt payload starts with ReceiptType.delivered (0x01)
      final singlePayload = BinaryProtocol.encodeReceiptPayload(
        receiptType: ReceiptType.delivered,
        originalTimestamp: 1000,
        originalSenderId: Uint8List(32),
      );
      expect(BinaryProtocol.decodeBatchReceiptPayload(singlePayload), isNull);
    });

    test('decodeBatchReceiptPayload returns null for empty data', () {
      expect(BinaryProtocol.decodeBatchReceiptPayload(Uint8List(0)), isNull);
    });

    test('decodeBatchReceiptPayload returns null for truncated batch', () {
      // 2-byte header saying count=3 but only 1 entry present
      final truncated = Uint8List(2 + 41); // count=3 but only 1 entry worth
      truncated[0] = 0xFF;
      truncated[1] = 3;
      expect(BinaryProtocol.decodeBatchReceiptPayload(truncated), isNull);
    });

    test('batch payload first byte (0xFF) is not confused with a receipt type', () {
      // Ensure decodeReceiptPayload does not crash on batch payload
      final batchPayload = BinaryProtocol.encodeBatchReceiptPayload([
        _makeReceipt(0xAA, 1000, ReceiptType.read),
      ]);
      // decodeReceiptPayload should still parse (it's > 41 bytes), but
      // the receiptType will be 0xFF which is neither delivered nor read.
      // The important thing is it does not throw.
      expect(() => BinaryProtocol.decodeReceiptPayload(batchPayload), returnsNormally);
    });
  });
}
