import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';
import '../../shared/hex_utils.dart';
import 'sodium_instance.dart';

/// Ed25519 packet signing and verification.
class Signatures {
  /// Cached [SecureKey] for the local signing private key.
  ///
  /// Re-using a single [SecureKey] wrapper avoids allocating a new libsodium
  /// secure buffer on every [sign] call (which is hot path — one per outbound
  /// packet). Populated lazily on first [sign] call.
  static SecureKey? _cachedSigningKey;
  static Uint8List? _cachedSigningKeyBytes;

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

    // Re-use the cached SecureKey if the key bytes haven't changed.
    if (_cachedSigningKey == null ||
        _cachedSigningKeyBytes == null ||
        !bytesEqual(_cachedSigningKeyBytes!, privateKey)) {
      _cachedSigningKey?.dispose();
      _cachedSigningKey = SecureKey.fromList(sodium, privateKey);
      _cachedSigningKeyBytes = privateKey;
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
    _cachedSigningKeyBytes = null;
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
