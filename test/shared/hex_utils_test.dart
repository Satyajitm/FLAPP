import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/shared/hex_utils.dart';

void main() {
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
