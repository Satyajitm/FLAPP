import 'dart:typed_data';
import '../../shared/hex_utils.dart';

/// A peer's identity on the mesh network.
///
/// Derived from the SHA-256 hash of the peer's static public key.
class PeerId {
  /// The raw 32-byte peer ID.
  final Uint8List bytes;

  PeerId(this.bytes) : assert(bytes.length == 32);

  /// Create a PeerId from a hex string.
  factory PeerId.fromHex(String hex) => PeerId(HexUtils.decode(hex));

  /// Hex-encoded peer ID string.
  String get hex => HexUtils.encode(bytes);

  /// Short display string (first 8 hex chars).
  String get shortId => hex.substring(0, 8);

  /// Broadcast address (all zeros).
  static final PeerId broadcast = PeerId(Uint8List(32));

  @override
  bool operator ==(Object other) =>
      other is PeerId && _bytesEqual(bytes, other.bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'PeerId($shortId...)';

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
