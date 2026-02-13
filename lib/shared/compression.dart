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
  static Uint8List? decompress(Uint8List data) {
    try {
      final codec = ZLibCodec();
      return Uint8List.fromList(codec.decode(data));
    } catch (_) {
      return null;
    }
  }
}
