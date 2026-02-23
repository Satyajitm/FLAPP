import 'dart:convert';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';
import '../crypto/sodium_instance.dart';

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
    final sodium = sodiumInstance;

    final nonce = sodium.randombytes.buf(
      sodium.crypto.aead.nonceBytes,
    );

    final ciphertext = sodium.crypto.aead.encrypt(
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
    final sodium = sodiumInstance;

    final nonceLen = sodium.crypto.aead.nonceBytes;
    if (data.length < nonceLen) return null;

    final nonce = Uint8List.sublistView(data, 0, nonceLen);
    final ciphertext = Uint8List.sublistView(data, nonceLen);

    try {
      return sodium.crypto.aead.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: SecureKey.fromList(sodium, groupKey),
      );
    } catch (_) {
      return null; // Decryption failed — wrong group key
    }
  }

  /// Generate a cryptographically random salt for use with [deriveGroupKey].
  ///
  /// Each group must use its own unique salt. Because the derived key (not the
  /// passphrase) is persisted, the salt itself does not need to be stored.
  Uint8List generateSalt() {
    final sodium = sodiumInstance;
    return sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
  }

  /// Derive a 32-byte group key from [passphrase] and a random [salt] using Argon2id.
  ///
  /// [salt] must be [sodium.crypto.pwhash.saltBytes] bytes. Use [generateSalt]
  /// to create a fresh random salt for each new group.
  Uint8List deriveGroupKey(String passphrase, Uint8List salt) {
    final sodium = sodiumInstance;

    // ignore: deprecated_member_use
    final key = sodium.crypto.pwhash(
      outLen: 32,
      password: passphrase.toCharArray(),
      salt: salt,
      // Fix: opsLimitModerate (was opsLimitInteractive) for stronger brute-force resistance.
      // ignore: deprecated_member_use
      opsLimit: sodium.crypto.pwhash.opsLimitModerate,
      // ignore: deprecated_member_use
      memLimit: sodium.crypto.pwhash.memLimitModerate,
    );
    final bytes = key.extractBytes();
    key.dispose();
    return bytes;
  }

  /// Generate a deterministic group ID from the passphrase.
  String generateGroupId(String passphrase) {
    final sodium = sodiumInstance;
    final hash = sodium.crypto.genericHash(
      message: Uint8List.fromList(utf8.encode('fluxon-group-id:$passphrase')),
      outLen: 16,
    );
    return hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
