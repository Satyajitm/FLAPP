import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';

void main() {
  group('FluxonPacket immutability', () {
    test('signature field is final and set at construction', () {
      final sig = Uint8List(64)..fillRange(0, 64, 0xAA);
      final packet = FluxonPacket(
        type: MessageType.chat,
        ttl: 5,
        timestamp: 1700000000000,
        sourceId: Uint8List(32),
        destId: Uint8List(32),
        payload: Uint8List(0),
        signature: sig,
      );

      expect(packet.signature, equals(sig));
    });

    test('withSignature creates new packet with signature', () {
      final packet = FluxonPacket(
        type: MessageType.chat,
        ttl: 5,
        timestamp: 1700000000000,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xAA),
        destId: Uint8List(32),
        payload: Uint8List.fromList([1, 2, 3]),
      );

      expect(packet.signature, isNull);

      final sig = Uint8List(64)..fillRange(0, 64, 0xFF);
      final signed = packet.withSignature(sig);

      // Original is unchanged
      expect(packet.signature, isNull);
      // New packet has the signature
      expect(signed.signature, isNotNull);
      expect(signed.signature, equals(sig));
      // Other fields are preserved
      expect(signed.type, equals(packet.type));
      expect(signed.ttl, equals(packet.ttl));
      expect(signed.timestamp, equals(packet.timestamp));
      expect(signed.payload, equals(packet.payload));
    });

    test('withSignature creates a deep copy (source isolation)', () {
      final packet = FluxonPacket(
        type: MessageType.chat,
        ttl: 3,
        timestamp: 1700000000000,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xCC),
        destId: Uint8List(32),
        payload: Uint8List.fromList([10, 20]),
      );

      final sig = Uint8List(64)..fillRange(0, 64, 0xBB);
      final signed = packet.withSignature(sig);

      // Mutating the original sig array should not affect the signed packet
      sig.fillRange(0, 64, 0x00);
      expect(signed.signature!.first, equals(0xBB));
    });

    test('withDecrementedTTL preserves signature', () {
      final sig = Uint8List(64)..fillRange(0, 64, 0xDD);
      final packet = FluxonPacket(
        type: MessageType.chat,
        ttl: 5,
        timestamp: 1700000000000,
        sourceId: Uint8List(32),
        destId: Uint8List(32),
        payload: Uint8List(0),
        signature: sig,
      );

      final relayed = packet.withDecrementedTTL();
      expect(relayed.ttl, equals(4));
      expect(relayed.signature, equals(sig));
    });

    test('all fields are preserved through encode/decode', () {
      final sig = Uint8List(64)..fillRange(0, 64, 0xEE);
      final packet = FluxonPacket(
        type: MessageType.emergencyAlert,
        ttl: 7,
        flags: 3,
        timestamp: 1700000000000,
        sourceId: Uint8List(32)..fillRange(0, 32, 0x11),
        destId: Uint8List(32),
        payload: Uint8List.fromList([5, 10, 15]),
        signature: sig,
      );

      final encoded = packet.encodeWithSignature();
      final decoded = FluxonPacket.decode(encoded, hasSignature: true);

      expect(decoded, isNotNull);
      expect(decoded!.type, equals(MessageType.emergencyAlert));
      expect(decoded.ttl, equals(7));
      expect(decoded.flags, equals(3));
      expect(decoded.signature, equals(sig));
    });
  });
}
