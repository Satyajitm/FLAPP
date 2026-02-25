import 'dart:typed_data';

/// PKCS#7 message padding for fixed-size packet payloads.
///
/// Ported from Bitchat's MessagePadding.
class MessagePadding {
  /// Pads [data] to the nearest multiple of [blockSize] using PKCS#7.
  static Uint8List pad(Uint8List data, {int blockSize = 16}) {
    final padLength = blockSize - (data.length % blockSize);
    final padded = Uint8List(data.length + padLength);
    padded.setAll(0, data);
    for (var i = data.length; i < padded.length; i++) {
      padded[i] = padLength;
    }
    return padded;
  }

  /// Removes PKCS#7 padding from [data].
  ///
  /// Returns null if padding is invalid.
  ///
  /// MED-N1: Uses constant-time comparison to prevent padding oracle attacks.
  /// All padding bytes are always checked regardless of where the first error
  /// occurs. Must only be called on data that has already been AEAD-verified.
  static Uint8List? unpad(Uint8List data) {
    if (data.isEmpty) return null;
    final padLength = data.last;
    if (padLength == 0 || padLength > data.length) return null;

    // Constant-time: XOR-accumulate all deviations without early return.
    int diff = 0;
    for (var i = data.length - padLength; i < data.length; i++) {
      diff |= data[i] ^ padLength;
    }
    if (diff != 0) return null;

    return Uint8List.sublistView(data, 0, data.length - padLength);
  }
}
