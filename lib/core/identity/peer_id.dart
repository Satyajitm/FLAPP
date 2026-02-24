import 'dart:typed_data';
import '../../shared/hex_utils.dart';

/// A peer's identity on the mesh network.
///
/// Derived from the SHA-256 hash of the peer's static public key.
class PeerId {
  /// The raw 32-byte peer ID.
  final Uint8List bytes;

  /// Cached hash code — computed once at construction time.
  final int _hashCode;

  PeerId(this.bytes)
      : assert(bytes.length == 32),
        _hashCode = Object.hashAll(bytes);

  /// Create a PeerId from a hex string.
  ///
  /// Throws [FormatException] if [hex] is not valid hex or not 32 bytes.
  factory PeerId.fromHex(String hex) {
    try {
      final bytes = HexUtils.decode(hex);
      if (bytes.length != 32) {
        throw FormatException('PeerId must be 32 bytes, got ${bytes.length}');
      }
      return PeerId(bytes);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Invalid hex peer ID: $e');
    }
  }

  /// Hex-encoded peer ID string.
  String get hex => HexUtils.encode(bytes);

  /// Short display string (first 8 hex chars).
  String get shortId => hex.substring(0, 8);

  /// Broadcast address (all zeros).
  static final PeerId broadcast = PeerId(Uint8List(32));

  @override
  bool operator ==(Object other) =>
      other is PeerId && bytesEqual(bytes, other.bytes);

  @override
  int get hashCode => _hashCode;

  @override
  String toString() => 'PeerId($shortId...)';
}
