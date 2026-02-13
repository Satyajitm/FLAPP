import 'dart:convert';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';

/// Handles symmetric encryption/decryption for group communication.
///
/// Extracted from [GroupManager] to satisfy SRP: group lifecycle management
/// is separate from cryptographic operations.
class GroupCipher {
  /// Encrypt data with the given group key using ChaCha20-Poly1305.
  ///
  /// Returns nonce prepended to ciphertext, or null if [groupKey] is null.
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey) {
    if (groupKey == null) return null;
    final sodium = SodiumInit.sodium;

    final nonce = sodium.randombytes.buf(
      sodium.crypto.aead.chacha20Poly1305Ietf.nonceBytes,
    );

    final ciphertext = sodium.crypto.aead.chacha20Poly1305Ietf.encrypt(
      message: plaintext,
      nonce: nonce,
      key: SecureKey.fromList(sodium, groupKey),
    );

    // Prepend nonce to ciphertext
    final result = Uint8List(nonce.length + ciphertext.length);
    result.setAll(0, nonce);
    result.setAll(nonce.length, ciphertext);
    return result;
  }

  /// Decrypt data with the given group key.
  ///
  /// Expects nonce prepended to ciphertext. Returns null on failure.
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey) {
    if (groupKey == null) return null;
    final sodium = SodiumInit.sodium;

    final nonceLen = sodium.crypto.aead.chacha20Poly1305Ietf.nonceBytes;
    if (data.length < nonceLen) return null;

    final nonce = Uint8List.sublistView(data, 0, nonceLen);
    final ciphertext = Uint8List.sublistView(data, nonceLen);

    try {
      return sodium.crypto.aead.chacha20Poly1305Ietf.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: SecureKey.fromList(sodium, groupKey),
      );
    } catch (_) {
      return null; // Decryption failed — wrong group key
    }
  }

  /// Derive a 32-byte group key from a passphrase using Argon2id.
  Uint8List deriveGroupKey(String passphrase) {
    final sodium = SodiumInit.sodium;
    final salt = sodium.crypto.genericHash(
      message: Uint8List.fromList(utf8.encode('fluxon-group-salt:$passphrase')),
      outLen: sodium.crypto.pwhash.saltBytes,
    );

    return sodium.crypto.pwhash(
      outLen: 32,
      password: passphrase.toCharArray(),
      salt: salt,
      opsLimit: sodium.crypto.pwhash.opsLimitInteractive,
      memLimit: sodium.crypto.pwhash.memLimitInteractive,
    );
  }

  /// Generate a deterministic group ID from the passphrase.
  String generateGroupId(String passphrase) {
    final sodium = SodiumInit.sodium;
    final hash = sodium.crypto.genericHash(
      message: Uint8List.fromList(utf8.encode('fluxon-group-id:$passphrase')),
      outLen: 16,
    );
    return hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
