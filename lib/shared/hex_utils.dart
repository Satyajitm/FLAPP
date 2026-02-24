import 'dart:typed_data';

/// Returns `true` if [a] and [b] have the same length and identical bytes.
///
/// Shared utility used by [PeerId], [MeshService], and [Signatures] to avoid
/// duplicating a byte-comparison loop in multiple files.
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 256-entry lookup table: byte value → two-character lowercase hex string.
/// Shared with [KeyGenerator.bytesToHex] — pre-computed once at startup.
final List<String> _hexTable = List.generate(
  256,
  (i) => i.toRadixString(16).padLeft(2, '0'),
  growable: false,
);

/// Hex encoding/decoding helpers.
class HexUtils {
  /// Encode bytes to lowercase hex string.
  ///
  /// Uses a pre-computed 256-entry lookup table to avoid calling
  /// [int.toRadixString] per byte (same table as [KeyGenerator.bytesToHex]).
  static String encode(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(_hexTable[b]);
    }
    return buf.toString();
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
