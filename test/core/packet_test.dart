import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';

void main() {
  group('FluxonPacket', () {
    late FluxonPacket packet;

    setUp(() {
      packet = FluxonPacket(
        type: MessageType.chat,
        ttl: 5,
        flags: 0,
        timestamp: 1700000000000,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xAA),
        destId: Uint8List(32), // broadcast
        payload: Uint8List.fromList([1, 2, 3, 4, 5]),
      );
    });

    test('encode and decode round-trip', () {
      final encoded = packet.encode();
      final decoded = FluxonPacket.decode(encoded, hasSignature: false);

      expect(decoded, isNotNull);
      expect(decoded!.type, equals(MessageType.chat));
      expect(decoded.ttl, equals(5));
      expect(decoded.timestamp, equals(1700000000000));
      expect(decoded.payload, equals(Uint8List.fromList([1, 2, 3, 4, 5])));
    });

    test('isBroadcast returns true for zero destId', () {
      expect(packet.isBroadcast, isTrue);
    });

    test('isBroadcast returns false for non-zero destId', () {
      final directed = FluxonPacket(
        type: MessageType.chat,
        ttl: 5,
        timestamp: 1700000000000,
        sourceId: Uint8List(32),
        destId: Uint8List(32)..fillRange(0, 32, 0xBB),
        payload: Uint8List(0),
      );
      expect(directed.isBroadcast, isFalse);
    });

    test('packetId is consistent', () {
      final id1 = packet.packetId;
      final id2 = packet.packetId;
      expect(id1, equals(id2));
    });

    test('withDecrementedTTL decrements by 1', () {
      final relayed = packet.withDecrementedTTL();
      expect(relayed.ttl, equals(4));
      expect(relayed.type, equals(packet.type));
      expect(relayed.timestamp, equals(packet.timestamp));
    });

    test('withDecrementedTTL does not go below 0', () {
      final zeroTTL = FluxonPacket(
        type: MessageType.chat,
        ttl: 0,
        timestamp: 1700000000000,
        sourceId: Uint8List(32),
        destId: Uint8List(32),
        payload: Uint8List(0),
      );
      expect(zeroTTL.withDecrementedTTL().ttl, equals(0));
    });

    test('decode rejects invalid version', () {
      final encoded = packet.encode();
      encoded[0] = 99; // invalid version
      expect(FluxonPacket.decode(encoded, hasSignature: false), isNull);
    });

    test('decode rejects too-short data', () {
      expect(FluxonPacket.decode(Uint8List(10), hasSignature: false), isNull);
    });

    test('encode with signature appends 64 bytes', () {
      final signed = packet.withSignature(Uint8List(64)..fillRange(0, 64, 0xFF));
      final withSig = signed.encodeWithSignature();
      final withoutSig = packet.encode();
      expect(withSig.length, equals(withoutSig.length + 64));
    });
  });

  group('MessageType', () {
    test('fromValue returns correct type', () {
      expect(MessageType.fromValue(0x02), equals(MessageType.chat));
      expect(MessageType.fromValue(0x09), equals(MessageType.locationUpdate));
      expect(MessageType.fromValue(0x0D), equals(MessageType.emergencyAlert));
    });

    test('fromValue returns null for unknown value', () {
      expect(MessageType.fromValue(0xFF), isNull);
    });
  });
}
