import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';

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
}
