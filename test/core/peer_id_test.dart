import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';

void main() {
  group('PeerId', () {
    test('equality – same bytes are equal', () {
      final a = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      final b = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      expect(a, equals(b));
    });

    test('equality – different bytes are not equal', () {
      final a = PeerId(Uint8List(32));
      final b = PeerId(Uint8List.fromList(List.generate(32, (i) => i + 1)));
      expect(a, isNot(equals(b)));
    });

    test('hashCode – equal peers have equal hashCode', () {
      final a = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      final b = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('broadcast is all zeros', () {
      expect(PeerId.broadcast.bytes, everyElement(0));
      expect(PeerId.broadcast.bytes.length, 32);
    });

    test('broadcast equals another all-zero PeerId', () {
      expect(PeerId.broadcast, equals(PeerId(Uint8List(32))));
    });

    test('fromHex round-trip', () {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i * 3 & 0xFF));
      final peer = PeerId(bytes);
      final restored = PeerId.fromHex(peer.hex);
      expect(restored, equals(peer));
    });

    test('fromHex rejects wrong length (too short)', () {
      expect(() => PeerId.fromHex('aabb'), throwsFormatException);
    });

    test('fromHex rejects too-long hex string', () {
      // 66 hex chars → 33 bytes → FormatException
      expect(() => PeerId.fromHex('a' * 66), throwsFormatException);
    });

    test('fromHex rejects invalid hex characters', () {
      final badHex = 'z' * 64;
      expect(() => PeerId.fromHex(badHex), throwsFormatException);
    });

    test('hex property returns lowercase 64-char string', () {
      final peer = PeerId(Uint8List(32));
      expect(peer.hex.length, 64);
      expect(peer.hex, equals(peer.hex.toLowerCase()));
    });

    test('shortId is first 8 hex chars', () {
      final peer = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      expect(peer.shortId, equals(peer.hex.substring(0, 8)));
    });

    test('toString contains shortId', () {
      final peer = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      expect(peer.toString(), contains(peer.shortId));
    });
  });
}
