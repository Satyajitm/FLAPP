import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';

void main() {
  Uint8List makePeerId(int fillByte) =>
      Uint8List(32)..fillRange(0, 32, fillByte);

  group('BinaryProtocol discovery payload', () {
    test('round-trip with zero neighbors', () {
      final encoded = BinaryProtocol.encodeDiscoveryPayload(neighbors: []);
      final decoded = BinaryProtocol.decodeDiscoveryPayload(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.neighbors, isEmpty);
    });

    test('round-trip with one neighbor', () {
      final neighbor = makePeerId(0xAA);
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: [neighbor]);
      final decoded = BinaryProtocol.decodeDiscoveryPayload(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.neighbors, hasLength(1));
      expect(decoded.neighbors[0], equals(neighbor));
    });

    test('round-trip with five neighbors', () {
      final neighbors = [
        makePeerId(0x01),
        makePeerId(0x02),
        makePeerId(0x03),
        makePeerId(0x04),
        makePeerId(0x05),
      ];
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: neighbors);
      final decoded = BinaryProtocol.decodeDiscoveryPayload(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.neighbors, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(decoded.neighbors[i], equals(neighbors[i]));
      }
    });

    test('encoded size is correct', () {
      final neighbors = [makePeerId(0xAA), makePeerId(0xBB)];
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: neighbors);

      // 1 byte count + 2 * 32 bytes
      expect(encoded.length, equals(1 + 2 * 32));
    });

    test('decode returns null for empty data', () {
      expect(
        BinaryProtocol.decodeDiscoveryPayload(Uint8List(0)),
        isNull,
      );
    });

    test('decode returns null for truncated data', () {
      // Header says 2 neighbors but only has data for 1
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: [makePeerId(0xAA)]);
      // Tamper with the neighbor count
      encoded[0] = 2;

      expect(BinaryProtocol.decodeDiscoveryPayload(encoded), isNull);
    });

    test('neighbor peer IDs are independent copies', () {
      final original = makePeerId(0xAA);
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: [original]);
      final decoded = BinaryProtocol.decodeDiscoveryPayload(encoded);

      // Mutate decoded neighbor — should not affect original
      decoded!.neighbors[0][0] = 0xFF;
      expect(original[0], equals(0xAA));
    });

    test('decode with count=0 and just 1 byte returns empty neighbors', () {
      final data = Uint8List(1);
      data[0] = 0; // count = 0
      final decoded = BinaryProtocol.decodeDiscoveryPayload(data);

      expect(decoded, isNotNull);
      expect(decoded!.neighbors, isEmpty);
    });

    test('decode ignores trailing bytes beyond declared count', () {
      // Encode 1 neighbor, but append extra garbage bytes
      final oneNeighbor = BinaryProtocol.encodeDiscoveryPayload(
        neighbors: [makePeerId(0xAA)],
      );
      // Append 32 extra bytes (looks like another neighbor but count=1)
      final extended = Uint8List(oneNeighbor.length + 32);
      extended.setAll(0, oneNeighbor);
      extended.fillRange(oneNeighbor.length, extended.length, 0xFF);

      final decoded = BinaryProtocol.decodeDiscoveryPayload(extended);
      expect(decoded, isNotNull);
      expect(decoded!.neighbors, hasLength(1)); // Only 1, not 2
      expect(decoded.neighbors[0], equals(makePeerId(0xAA)));
    });

    test('round-trip with maximum representable neighbors (255)', () {
      final neighbors = List.generate(255, (i) => makePeerId(i & 0xFF));
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: neighbors);
      final decoded = BinaryProtocol.decodeDiscoveryPayload(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.neighbors, hasLength(255));
      // Check first and last
      expect(decoded.neighbors[0], equals(makePeerId(0)));
      expect(decoded.neighbors[254], equals(makePeerId(254)));
    });

    test('encoded buffer size for max neighbors', () {
      final neighbors = List.generate(255, (i) => makePeerId(i & 0xFF));
      final encoded =
          BinaryProtocol.encodeDiscoveryPayload(neighbors: neighbors);
      // 1 byte count + 255 * 32 bytes
      expect(encoded.length, equals(1 + 255 * 32));
    });
  });
}
