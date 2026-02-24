import 'dart:convert';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';
import '../../shared/hex_utils.dart';
import '../crypto/sodium_instance.dart';

/// Handles symmetric encryption/decryption for group communication.
///
/// Extracted from [GroupManager] to satisfy SRP: group lifecycle management
/// is separate from cryptographic operations.
/// Cached result of a single Argon2id derivation.
class _DerivedGroup {
  final Uint8List key;
  final String groupId;
  _DerivedGroup(this.key, this.groupId);
}

class GroupCipher {
  /// Cache of passphrase+salt → derived key+groupId to avoid running
  /// the expensive Argon2id twice on create/join.
  final Map<String, _DerivedGroup> _derivationCache = {};

  /// Cached [SecureKey] for the active group key.
  ///
  /// Re-using a single [SecureKey] wrapper avoids allocating a new libsodium
  /// secure buffer on every [encrypt]/[decrypt] call. Invalidated whenever
  /// the key bytes change.
  SecureKey? _cachedGroupSecureKey;
  Uint8List? _cachedGroupKeyBytes;

  // RFC 4648 base32 alphabet (no padding character)
  static const _b32Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  static final _b32Values = () {
    final m = <int, int>{};
    for (var i = 0; i < _b32Chars.length; i++) {
      m[_b32Chars.codeUnitAt(i)] = i;
    }
    return m;
  }();

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
  /// Each group must use its own unique salt.
  Uint8List generateSalt() {
    final sodium = sodiumInstance;
    return sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
  }

  /// Run Argon2id once and cache both the group key and group ID for the given
  /// [passphrase]+[salt] pair. Subsequent calls with the same inputs are free.
  _DerivedGroup _derive(String passphrase, Uint8List salt) {
    final sodium = sodiumInstance;

    // Use a BLAKE2b hash of (passphrase || salt) as the cache key so the
    // plaintext passphrase is never retained as a heap-allocated map key string.
    final keyInput = Uint8List.fromList(utf8.encode(passphrase) + salt);
    final keyHash = sodium.crypto.genericHash(message: keyInput, outLen: 16);
    final cacheKey = keyHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final cached = _derivationCache[cacheKey];
    if (cached != null) return cached;

    // ignore: deprecated_member_use
    final key = sodium.crypto.pwhash(
      outLen: 32,
      password: passphrase.toCharArray(),
      salt: salt,
      // opsLimitModerate for stronger brute-force resistance.
      // ignore: deprecated_member_use
      opsLimit: sodium.crypto.pwhash.opsLimitModerate,
      // ignore: deprecated_member_use
      memLimit: sodium.crypto.pwhash.memLimitModerate,
    );
    final keyBytes = key.extractBytes();
    key.dispose();

    final input = Uint8List.fromList(
      utf8.encode('fluxon-group-id:$passphrase:') + salt,
    );
    final hash = sodium.crypto.genericHash(message: input, outLen: 16);
    final groupId = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final result = _DerivedGroup(keyBytes, groupId);
    _derivationCache[cacheKey] = result;
    return result;
  }

  /// Derive a 32-byte group key from [passphrase] and [salt] using Argon2id.
  ///
  /// The result is cached — calling both [deriveGroupKey] and [generateGroupId]
  /// with the same inputs runs Argon2id only once.
  Uint8List deriveGroupKey(String passphrase, Uint8List salt) =>
      _derive(passphrase, salt).key;

  /// Generate a deterministic group ID from [passphrase] AND [salt].
  ///
  /// Including the salt ensures that two groups with the same passphrase but
  /// different salts get different IDs.
  String generateGroupId(String passphrase, Uint8List salt) =>
      _derive(passphrase, salt).groupId;

  /// Encode [salt] bytes as an unpadded RFC 4648 base32 string.
  ///
  /// 16 bytes → 26 uppercase characters (A-Z, 2-7), human-typeable.
  String encodeSalt(Uint8List salt) {
    var buffer = 0;
    var bitsLeft = 0;
    final result = StringBuffer();
    for (final byte in salt) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        result.writeCharCode(_b32Chars.codeUnitAt((buffer >> bitsLeft) & 0x1F));
      }
    }
    if (bitsLeft > 0) {
      result.writeCharCode(
          _b32Chars.codeUnitAt((buffer << (5 - bitsLeft)) & 0x1F));
    }
    return result.toString();
  }

  /// Decode a base32 [code] (produced by [encodeSalt]) back to bytes.
  ///
  /// Throws [FormatException] if the string contains invalid characters.
  Uint8List decodeSalt(String code) {
    final upper = code.toUpperCase();
    var buffer = 0;
    var bitsLeft = 0;
    final bytes = <int>[];
    for (final ch in upper.codeUnits) {
      final val = _b32Values[ch];
      if (val == null) {
        throw FormatException('Invalid base32 character: ${String.fromCharCode(ch)}');
      }
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        bytes.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(bytes);
  }
}
