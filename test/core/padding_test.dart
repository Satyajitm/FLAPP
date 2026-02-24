import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/padding.dart';

void main() {
  group('MessagePadding', () {
    group('pad', () {
      test('pads data shorter than block size', () {
        final data = Uint8List.fromList([1, 2, 3]);
        final padded = MessagePadding.pad(data, blockSize: 16);
        expect(padded.length, 16);
        for (var i = 3; i < 16; i++) {
          expect(padded[i], 13);
        }
      });

      test('data already a multiple of blockSize gets a full extra block', () {
        final data = Uint8List(16);
        final padded = MessagePadding.pad(data, blockSize: 16);
        expect(padded.length, 32);
        for (var i = 16; i < 32; i++) {
          expect(padded[i], 16);
        }
      });

      test('empty data pads to one full block', () {
        final padded = MessagePadding.pad(Uint8List(0), blockSize: 8);
        expect(padded.length, 8);
        expect(padded, everyElement(8));
      });

      test('pad with custom block size of 32', () {
        final data = Uint8List.fromList([0xFF]);
        final padded = MessagePadding.pad(data, blockSize: 32);
        expect(padded.length, 32);
        expect(padded[0], 0xFF);
        for (var i = 1; i < 32; i++) {
          expect(padded[i], 31);
        }
      });

      test('original bytes are preserved at start of padded output', () {
        final data = Uint8List.fromList([10, 20, 30]);
        final padded = MessagePadding.pad(data);
        expect(padded[0], 10);
        expect(padded[1], 20);
        expect(padded[2], 30);
      });
    });

    group('unpad', () {
      test('round-trip pad → unpad returns original data', () {
        final data = Uint8List.fromList([10, 20, 30, 40, 50]);
        final padded = MessagePadding.pad(data);
        final unpadded = MessagePadding.unpad(padded);
        expect(unpadded, equals(data));
      });

      test('returns null for empty data', () {
        expect(MessagePadding.unpad(Uint8List(0)), isNull);
      });

      test('returns null for invalid padding byte (0)', () {
        final data = Uint8List.fromList([1, 2, 3, 0]);
        expect(MessagePadding.unpad(data), isNull);
      });

      test('returns null when padding byte exceeds data length', () {
        final data = Uint8List.fromList([1, 255]);
        expect(MessagePadding.unpad(data), isNull);
      });

      test('returns null when padding bytes are inconsistent', () {
        // Last byte says 3 but not all last 3 bytes are 3
        final data = Uint8List.fromList([1, 2, 5, 3]);
        expect(MessagePadding.unpad(data), isNull);
      });

      test('single-byte data with valid padding (1) gives empty result', () {
        final data = Uint8List.fromList([1]);
        final result = MessagePadding.unpad(data);
        expect(result, isNotNull);
        expect(result!.length, 0);
      });

      test('round-trip with block size 32', () {
        final data = Uint8List.fromList(List.generate(10, (i) => i));
        final padded = MessagePadding.pad(data, blockSize: 32);
        final unpadded = MessagePadding.unpad(padded);
        expect(unpadded, equals(data));
      });
    });
  });
}
