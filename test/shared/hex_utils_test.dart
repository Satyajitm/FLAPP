import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/shared/hex_utils.dart';

void main() {
  // HIGH-C3: Constant-time comparison tests.
  group('bytesEqual — constant-time XOR accumulator', () {
    test('equal slices return true', () {
      final a = Uint8List.fromList([0x01, 0x02, 0x03]);
      final b = Uint8List.fromList([0x01, 0x02, 0x03]);
      expect(bytesEqual(a, b), isTrue);
    });

    test('slices differing in first byte return false', () {
      final a = Uint8List.fromList([0xFF, 0x02, 0x03]);
      final b = Uint8List.fromList([0x00, 0x02, 0x03]);
      expect(bytesEqual(a, b), isFalse);
    });

    test('slices differing only in last byte return false', () {
      final a = Uint8List.fromList([0x01, 0x02, 0xFF]);
      final b = Uint8List.fromList([0x01, 0x02, 0x00]);
      expect(bytesEqual(a, b), isFalse);
    });

    test('different lengths return false without comparing bytes', () {
      final a = Uint8List.fromList([0x01, 0x02]);
      final b = Uint8List.fromList([0x01, 0x02, 0x03]);
      expect(bytesEqual(a, b), isFalse);
    });

    test('empty slices are equal', () {
      expect(bytesEqual(Uint8List(0), Uint8List(0)), isTrue);
    });

    test('all-zero slices are equal', () {
      final a = Uint8List(16);
      final b = Uint8List(16);
      expect(bytesEqual(a, b), isTrue);
    });

    test('all-0xFF slices are equal', () {
      final a = Uint8List(16)..fillRange(0, 16, 0xFF);
      final b = Uint8List(16)..fillRange(0, 16, 0xFF);
      expect(bytesEqual(a, b), isTrue);
    });

    test('slices differing in middle byte return false', () {
      final a = Uint8List.fromList([0x01, 0xFF, 0x03]);
      final b = Uint8List.fromList([0x01, 0x00, 0x03]);
      expect(bytesEqual(a, b), isFalse);
    });

    test('single-byte equal', () {
      final a = Uint8List.fromList([0xAB]);
      final b = Uint8List.fromList([0xAB]);
      expect(bytesEqual(a, b), isTrue);
    });

    test('single-byte different', () {
      final a = Uint8List.fromList([0xAB]);
      final b = Uint8List.fromList([0xAC]);
      expect(bytesEqual(a, b), isFalse);
    });
  });

  group('HexUtils', () {
    group('encode', () {
      test('encodes known bytes to lowercase hex', () {
        final bytes = Uint8List.fromList([0x00, 0xFF, 0xAB, 0x12]);
        expect(HexUtils.encode(bytes), equals('00ffab12'));
      });

      test('encodes empty bytes to empty string', () {
        expect(HexUtils.encode(Uint8List(0)), equals(''));
      });

      test('output is always lowercase', () {
        final bytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        final hex = HexUtils.encode(bytes);
        expect(hex, equals(hex.toLowerCase()));
      });

      test('output length is 2× byte count', () {
        final bytes = Uint8List.fromList(List.generate(32, (i) => i));
        expect(HexUtils.encode(bytes).length, 64);
      });

      test('single zero byte encodes to 00', () {
        expect(HexUtils.encode(Uint8List.fromList([0x00])), equals('00'));
      });

      test('single 0xFF byte encodes to ff', () {
        expect(HexUtils.encode(Uint8List.fromList([0xFF])), equals('ff'));
      });
    });

    group('decode', () {
      test('decodes known hex to bytes', () {
        final bytes = HexUtils.decode('00ffab12');
        expect(bytes, equals(Uint8List.fromList([0x00, 0xFF, 0xAB, 0x12])));
      });

      test('decodes uppercase hex', () {
        final bytes = HexUtils.decode('DEADBEEF');
        expect(bytes, equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])));
      });

      test('decodes empty string to empty bytes', () {
        expect(HexUtils.decode('').length, 0);
      });

      test('round-trip encode then decode returns original', () {
        final original = Uint8List.fromList(List.generate(32, (i) => i * 5 & 0xFF));
        expect(HexUtils.decode(HexUtils.encode(original)), equals(original));
      });

      test('round-trip decode then encode returns original string', () {
        const hex = 'deadbeef0102030405060708090a0b0c';
        expect(HexUtils.encode(HexUtils.decode(hex)), equals(hex));
      });
    });
  });
}
