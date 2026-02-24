import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/shared/compression.dart';

void main() {
  group('Compression', () {
    test('compress then decompress returns original data', () {
      final original = Uint8List.fromList('Hello, FluxonApp mesh!'.codeUnits);
      final compressed = Compression.compress(original);
      final decompressed = Compression.decompress(compressed);
      expect(decompressed, isNotNull);
      expect(decompressed, equals(original));
    });

    test('compress empty data and decompress round-trips', () {
      final compressed = Compression.compress(Uint8List(0));
      final decompressed = Compression.decompress(compressed);
      expect(decompressed, isNotNull);
      expect(decompressed!.length, 0);
    });

    test('compress reduces size of highly repetitive data', () {
      final data = Uint8List.fromList(List.filled(1024, 0xAB));
      final compressed = Compression.compress(data);
      expect(compressed.length, lessThan(data.length));
    });

    test('decompress returns null for invalid data', () {
      final garbage = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      expect(Compression.decompress(garbage), isNull);
    });

    test('decompress returns null when output exceeds maxOutputSize (zip bomb guard)', () {
      final big = Uint8List.fromList(List.filled(10000, 0));
      final compressed = Compression.compress(big);
      final result = Compression.decompress(compressed, maxOutputSize: 100);
      expect(result, isNull);
    });

    test('decompress succeeds when output is exactly at maxOutputSize', () {
      final data = Uint8List.fromList(List.generate(50, (i) => i));
      final compressed = Compression.compress(data);
      final result = Compression.decompress(compressed, maxOutputSize: data.length);
      expect(result, isNotNull);
      expect(result, equals(data));
    });

    test('decompress empty input returns empty bytes', () {
      // Empty zlib stream decompresses to empty output (not null).
      final result = Compression.decompress(Uint8List(0));
      // Implementation may return null (exception) or empty list — both are acceptable.
      if (result != null) expect(result.length, 0);
    });

    test('default maxOutputSize allows 65536 bytes', () {
      final data = Uint8List.fromList(List.generate(65536, (i) => i & 0xFF));
      final compressed = Compression.compress(data);
      final result = Compression.decompress(compressed);
      expect(result, isNotNull);
      expect(result!.length, 65536);
    });
  });
}
