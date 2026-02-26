import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import '../../shared/hex_utils.dart';
import '../crypto/sodium_instance.dart';

/// Top-level Argon2id derivation that can run inside [Isolate.run].
///
/// Initializes its own sodium instance so it can run in a background isolate
/// without accessing the main isolate's [sodiumInstance] global.
/// Returns `(key bytes, group ID hex string)`.
Future<(Uint8List, String)> _deriveInIsolate(
    (String passphrase, Uint8List salt) args) async {
  final (passphrase, salt) = args;
  // ignore: deprecated_member_use
  final sodium = await SodiumSumoInit.init();
  // ignore: deprecated_member_use
  final key = sodium.crypto.pwhash(
    outLen: 32,
    password: passphrase.toCharArray(),
    salt: salt,
    // ignore: deprecated_member_use
    opsLimit: sodium.crypto.pwhash.opsLimitModerate,
    // ignore: deprecated_member_use
    memLimit: sodium.crypto.pwhash.memLimitModerate,
  );
  final keyBytes = key.extractBytes();
  key.dispose();

  final idInput = Uint8List.fromList(
    utf8.encode('fluxon-group-id:') + keyBytes,
  );
  final hash = sodium.crypto.genericHash(message: idInput, outLen: 16);
  final groupId = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return (keyBytes, groupId);
}

/// Handles symmetric encryption/decryption for group communication.
///
/// Extracted from [GroupManager] to satisfy SRP: group lifecycle management
/// is separate from cryptographic operations.
/// Cached result of a single Argon2id derivation.
class DerivedGroup {
  final Uint8List key;
  final String groupId;
  DerivedGroup(this.key, this.groupId);
}

class GroupCipher {
  /// Cache of passphrase+salt → derived key+groupId to avoid running
  /// the expensive Argon2id twice on create/join.
  final Map<String, DerivedGroup> _derivationCache = {};

  /// Cached [SecureKey] for the active group key.
  ///
  /// Re-using a single [SecureKey] wrapper avoids allocating a new libsodium
  /// secure buffer on every [encrypt]/[decrypt] call. Invalidated whenever
  /// the key bytes change.
  SecureKey? _cachedGroupSecureKey;

  /// MED-C5: Store a BLAKE2b-32 hash of the cached key instead of the raw bytes.
  /// This avoids keeping the actual key material in the GC-managed heap for
  /// the sole purpose of change-detection.
  Uint8List? _cachedGroupKeyHash;

  // RFC 4648 base32 alphabet (no padding character)
  static const _b32Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  static final _b32Values = () {
    final m = <int, int>{};
    for (var i = 0; i < _b32Chars.length; i++) {
      m[_b32Chars.codeUnitAt(i)] = i;
    }
    return m;
  }();

  /// Return (or create) a cached [SecureKey] for [groupKey].
  ///
  /// Avoids allocating a new libsodium secure buffer on every encrypt/decrypt
  /// call. The cache is invalidated when the key bytes change.
  ///
  /// MED-C5: Change-detection uses a BLAKE2b-32 hash of the key rather than
  /// storing the raw key bytes in the GC-managed Dart heap.
  SecureKey _getGroupSecureKey(Uint8List groupKey) {
    final sodium = sodiumInstance;
    final incoming = sodium.crypto.genericHash(message: groupKey, outLen: 32);
    final cached = _cachedGroupSecureKey;
    final cachedHash = _cachedGroupKeyHash;
    if (cached != null &&
        cachedHash != null &&
        bytesEqual(cachedHash, incoming)) {
      return cached;
    }
    cached?.dispose();
    final key = SecureKey.fromList(sodium, groupKey);
    _cachedGroupSecureKey = key;
    _cachedGroupKeyHash = incoming;
    return key;
  }

  /// Encrypt data with the given group key using ChaCha20-Poly1305.
  ///
  /// MED-C1: [additionalData] is bound into the AEAD tag so that ciphertext
  /// from one message type cannot be replayed as another type.
  /// Callers should pass the 1-byte [MessageType] value as AD.
  ///
  /// Returns nonce prepended to ciphertext, or null if [groupKey] is null.
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey, {Uint8List? additionalData}) {
    if (groupKey == null) return null;
    final sodium = sodiumInstance;

    final nonce = sodium.randombytes.buf(
      sodium.crypto.aead.nonceBytes,
    );

    final ciphertext = sodium.crypto.aead.encrypt(
      message: plaintext,
      nonce: nonce,
      key: _getGroupSecureKey(groupKey),
      additionalData: additionalData,
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
  /// MED-C1: [additionalData] must match what was passed to [encrypt].
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey, {Uint8List? additionalData}) {
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
        key: _getGroupSecureKey(groupKey),
        additionalData: additionalData,
      );
    } catch (_) {
      return null; // Decryption failed — wrong group key or mismatched AD
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
  DerivedGroup _derive(String passphrase, Uint8List salt) {
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

    // MED-C3: Derive group ID from the Argon2id key output, NOT from the raw
    // passphrase. Deriving from the passphrase directly allows fast brute-force
    // attacks with BLAKE2b. Deriving from the Argon2id output inherits the
    // full Argon2id work factor.
    final idInput = Uint8List.fromList(
      utf8.encode('fluxon-group-id:') + keyBytes,
    );
    final hash = sodium.crypto.genericHash(message: idInput, outLen: 16);
    final groupId = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final result = DerivedGroup(keyBytes, groupId);
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

  /// Async variant of [_derive] that runs Argon2id in a background isolate.
  ///
  /// Returns cached result immediately if available (cache hit is synchronous).
  /// On a cache miss, spawns a background isolate to avoid blocking the UI thread.
  Future<DerivedGroup> deriveAsync(String passphrase, Uint8List salt) async {
    final sodium = sodiumInstance;
    final keyInput = Uint8List.fromList(utf8.encode(passphrase) + salt);
    final keyHash = sodium.crypto.genericHash(message: keyInput, outLen: 16);
    final cacheKey =
        keyHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final cached = _derivationCache[cacheKey];
    if (cached != null) return cached;

    // Cache miss — run Argon2id in a background isolate to keep UI responsive.
    final (keyBytes, groupId) =
        await Isolate.run(() => _deriveInIsolate((passphrase, salt)));

    final result = DerivedGroup(keyBytes, groupId);
    _derivationCache[cacheKey] = result;
    return result;
  }

  /// HIGH-C2: Evict the derivation cache and zero all cached key material.
  ///
  /// Call this when leaving a group to prevent derived keys from lingering
  /// indefinitely in the GC heap.
  void clearCache() {
    // Zero all cached key bytes before removing from map.
    for (final entry in _derivationCache.values) {
      for (int i = 0; i < entry.key.length; i++) {
        entry.key[i] = 0;
      }
    }
    _derivationCache.clear();

    // Also clear the SecureKey wrapper cache and the key hash.
    _cachedGroupSecureKey?.dispose();
    _cachedGroupSecureKey = null;
    if (_cachedGroupKeyHash != null) {
      for (int i = 0; i < _cachedGroupKeyHash!.length; i++) {
        _cachedGroupKeyHash![i] = 0;
      }
      _cachedGroupKeyHash = null;
    }
  }

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
    final result = Uint8List.fromList(bytes);
    // MEDIUM: Validate decoded length matches the expected Argon2id salt size.
    // libsodium defines crypto_pwhash_SALTBYTES = 16 (constant across versions).
    // Using a constant avoids a sodiumInstance access at the decoding boundary.
    const expectedSaltBytes = 16; // crypto_pwhash_SALTBYTES
    if (result.length != expectedSaltBytes) {
      throw FormatException(
          'Invalid salt length: ${result.length} (expected $expectedSaltBytes)');
    }
    return result;
  }
}
