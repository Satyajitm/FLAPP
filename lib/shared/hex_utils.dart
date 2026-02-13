import 'dart:typed_data';

/// Hex encoding/decoding helpers.
class HexUtils {
  /// Encode bytes to lowercase hex string.
  static String encode(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Decode hex string to bytes.
  static Uint8List decode(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
