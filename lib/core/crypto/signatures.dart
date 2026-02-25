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

  /// CRIT-C3: A copy of the cached key bytes used for constant-time comparison.
  /// Stored as raw bytes so we can do a proper constant-time XOR comparison
  /// rather than relying on Object.hashAll which is order-dependent and
  /// not collision-resistant.
  static Uint8List? _cachedKeyBytes;

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

    // CRIT-C3: Use a constant-time XOR accumulator to compare the incoming
    // key against the cached key bytes. This prevents timing side-channels
    // that could leak information about when the key changes.
    final cachedBytes = _cachedKeyBytes;
    bool keyChanged = _cachedSigningKey == null ||
        cachedBytes == null ||
        cachedBytes.length != privateKey.length;
    if (!keyChanged) {
      int diff = 0;
      for (int i = 0; i < privateKey.length; i++) {
        diff |= cachedBytes[i] ^ privateKey[i];
      }
      keyChanged = diff != 0;
    }
    if (keyChanged) {
      _cachedSigningKey?.dispose();
      _cachedSigningKey = SecureKey.fromList(sodium, privateKey);
      // Keep a copy for future constant-time comparisons.
      _cachedKeyBytes = Uint8List.fromList(privateKey);
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
    // Zero the cached key bytes before discarding.
    if (_cachedKeyBytes != null) {
      for (int i = 0; i < _cachedKeyBytes!.length; i++) {
        _cachedKeyBytes![i] = 0;
      }
      _cachedKeyBytes = null;
    }
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
