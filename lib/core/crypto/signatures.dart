import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';
import 'sodium_instance.dart';

/// Ed25519 packet signing and verification.
class Signatures {
  /// Cached [SecureKey] for the local signing private key.
  ///
  /// Re-using a single [SecureKey] wrapper avoids allocating a new libsodium
  /// secure buffer on every [sign] call (which is hot path — one per outbound
  /// packet). Populated lazily on first [sign] call.
  static SecureKey? _cachedSigningKey;

  /// LOW-2: Hash of the cached key's bytes (for change detection).
  /// Using a hash avoids keeping the raw key bytes in Dart GC-managed heap.
  static int _cachedKeyHashCode = 0;

  /// Generate an Ed25519 signing key pair.
  static ({Uint8List privateKey, Uint8List publicKey}) generateSigningKeyPair() {
    final sodium = sodiumInstance;
    final keyPair = sodium.crypto.sign.keyPair();
    return (
      privateKey: keyPair.secretKey.extractBytes(),
      publicKey: Uint8List.fromList(keyPair.publicKey),
    );
  }

  /// Sign a message with an Ed25519 private key.
  ///
  /// Returns the 64-byte detached signature.
  ///
  /// The [SecureKey] wrapper for [privateKey] is cached after the first call so
  /// repeated signing (one per outbound packet) avoids repeated secure-memory
  /// allocations.
  static Uint8List sign(Uint8List message, Uint8List privateKey) {
    final sodium = sodiumInstance;

    // LOW-2: Use a hash of the key for change-detection instead of a raw copy.
    // This avoids retaining the private key bytes in GC-managed Dart heap.
    final keyHash = Object.hashAll(privateKey);
    if (_cachedSigningKey == null || _cachedKeyHashCode != keyHash) {
      _cachedSigningKey?.dispose();
      _cachedSigningKey = SecureKey.fromList(sodium, privateKey);
      _cachedKeyHashCode = keyHash;
    }

    return sodium.crypto.sign.detached(
      message: message,
      secretKey: _cachedSigningKey!,
    );
  }

  /// Clear the cached signing key (call when the local identity is reset).
  static void clearCache() {
    _cachedSigningKey?.dispose();
    _cachedSigningKey = null;
    _cachedKeyHashCode = 0;
  }


  /// Verify an Ed25519 detached signature.
  static bool verify(Uint8List message, Uint8List signature, Uint8List publicKey) {
    final sodium = sodiumInstance;
    try {
      return sodium.crypto.sign.verifyDetached(
        message: message,
        signature: signature,
        publicKey: publicKey,
      );
    } catch (_) {
      return false;
    }
  }
}
