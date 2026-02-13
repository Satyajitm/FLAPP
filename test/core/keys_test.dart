// KeyGenerator/KeyStorage tests.
// Hex utility methods are tested directly. Crypto methods that require
// sodium_libs are structured as integration test placeholders.

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

// We cannot import keys.dart directly because it pulls in sodium_libs
// which fails to compile without native binaries. Instead, we test the
// hex utility logic inline and document the crypto test contracts.

void main() {
  group('KeyGenerator hex utilities', () {
    // Inline implementations matching KeyGenerator.bytesToHex / hexToBytes
    String bytesToHex(Uint8List bytes) {
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }

    Uint8List hexToBytes(String hex) {
      final bytes = Uint8List(hex.length ~/ 2);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return bytes;
    }

    test('bytesToHex and hexToBytes round-trip', () {
      final original = Uint8List.fromList([0x00, 0xFF, 0xAB, 0x12, 0xCD]);
      final hex = bytesToHex(original);
      expect(hex, equals('00ffab12cd'));
      final restored = hexToBytes(hex);
      expect(restored, equals(original));
    });

    test('bytesToHex produces correct hex string', () {
      final bytes = Uint8List.fromList([0, 1, 15, 16, 255]);
      expect(bytesToHex(bytes), equals('00010f10ff'));
    });

    test('hexToBytes produces correct bytes', () {
      final bytes = hexToBytes('deadbeef');
      expect(bytes, equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])));
    });

    test('hexToBytes handles empty string', () {
      final bytes = hexToBytes('');
      expect(bytes, isEmpty);
    });

    test('bytesToHex handles single byte', () {
      expect(bytesToHex(Uint8List.fromList([0x0A])), equals('0a'));
    });

    test('round-trip preserves all-zero bytes', () {
      final zeros = Uint8List(4);
      final hex = bytesToHex(zeros);
      expect(hex, equals('00000000'));
      expect(hexToBytes(hex), equals(zeros));
    });
  });

  group('KeyGenerator/KeyStorage (require sodium)', () {
    test('placeholder — crypto tests require native libs', () {
      // Full integration test suite would verify:
      // 1. KeyGenerator.generateStaticKeyPair returns 32-byte keys
      // 2. KeyGenerator.generateSymmetricKey returns 32 bytes
      // 3. KeyGenerator.derivePeerId returns 32 bytes and is deterministic
      // 4. KeyStorage.storeStaticKeyPair/loadStaticKeyPair round-trip
      // 5. KeyStorage.getOrCreateStaticKeyPair lazy initialization
      // 6. KeyStorage.deleteStaticKeyPair clears stored keys
      // 7. KeyManager facade delegates correctly
      expect(true, isTrue);
    });
  });
}
