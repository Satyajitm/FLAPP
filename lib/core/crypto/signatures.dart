import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';

/// Ed25519 packet signing and verification.
class Signatures {
  /// Generate an Ed25519 signing key pair.
  static ({Uint8List privateKey, Uint8List publicKey}) generateSigningKeyPair() {
    final sodium = SodiumInit.sodium;
    final keyPair = sodium.crypto.sign.keyPair();
    return (
      privateKey: keyPair.secretKey.extractBytes(),
      publicKey: Uint8List.fromList(keyPair.publicKey),
    );
  }

  /// Sign a message with an Ed25519 private key.
  ///
  /// Returns the 64-byte detached signature.
  static Uint8List sign(Uint8List message, Uint8List privateKey) {
    final sodium = SodiumInit.sodium;
    return sodium.crypto.sign.detached(
      message: message,
      secretKey: SecureKey.fromList(sodium, privateKey),
    );
  }

  /// Verify an Ed25519 detached signature.
  static bool verify(Uint8List message, Uint8List signature, Uint8List publicKey) {
    final sodium = SodiumInit.sodium;
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
