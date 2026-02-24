import 'dart:io';
import 'dart:typed_data';

/// zlib compression utility for reducing payload sizes over BLE.
class Compression {
  /// Compress data using zlib (DEFLATE).
  static Uint8List compress(Uint8List data) {
    final codec = ZLibCodec(level: ZLibOption.defaultLevel);
    return Uint8List.fromList(codec.encode(data));
  }

  /// Decompress zlib-compressed data.
  ///
  /// [maxOutputSize] limits the decompressed output to guard against zip bombs.
  /// Returns null if decompression fails or the output exceeds [maxOutputSize].
  static Uint8List? decompress(Uint8List data, {int maxOutputSize = 65536}) {
    try {
      final codec = ZLibCodec();
      final decoded = codec.decode(data);
      if (decoded.length > maxOutputSize) return null; // Zip bomb protection
      return Uint8List.fromList(decoded);
    } catch (_) {
      return null;
    }
  }
}
