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

  /// INFO-N2: BLAKE2b-32 hash of the cached signing key, used for constant-time
  /// change detection. Storing the hash instead of the raw 64-byte private key
  /// avoids keeping a second copy of the private key in the GC-managed heap.
  static Uint8List? _cachedKeyHash;

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

    // INFO-N2 / CRIT-C3: Compute BLAKE2b-32 of the incoming key and compare
    // against the cached hash using a constant-time XOR accumulator. This avoids
    // keeping a raw copy of the 64-byte private key in the GC-managed heap while
    // still preventing timing side-channels on cache invalidation.
    final newHash = sodium.crypto.genericHash(message: privateKey, outLen: 32);
    final cachedHash = _cachedKeyHash;
    bool keyChanged = _cachedSigningKey == null || cachedHash == null;
    if (!keyChanged) {
      int diff = 0;
      for (int i = 0; i < 32; i++) {
        diff |= cachedHash![i] ^ newHash[i];
      }
      keyChanged = diff != 0;
    }
    if (keyChanged) {
      _cachedSigningKey?.dispose();
      _cachedSigningKey = SecureKey.fromList(sodium, privateKey);
      // Store only the hash — not the raw key bytes — to minimize GC heap exposure.
      _cachedKeyHash = newHash;
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
    // Zero the cached hash bytes before discarding.
    if (_cachedKeyHash != null) {
      for (int i = 0; i < _cachedKeyHash!.length; i++) {
        _cachedKeyHash![i] = 0;
      }
      _cachedKeyHash = null;
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
