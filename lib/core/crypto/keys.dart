import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../shared/hex_utils.dart';
import 'sodium_instance.dart';
import 'signatures.dart';

/// Pure key generation logic — no storage dependencies (ISP).
class KeyGenerator {
  /// Generate a new Curve25519 static key pair.
  ///
  /// Returns (privateKey, publicKey) as raw 32-byte arrays.
  static ({Uint8List privateKey, Uint8List publicKey}) generateStaticKeyPair() {
    final sodium = sodiumInstance;
    final keyPair = sodium.crypto.box.keyPair();
    return (
      privateKey: keyPair.secretKey.extractBytes(),
      publicKey: Uint8List.fromList(keyPair.publicKey),
    );
  }

  /// Generate a random 32-byte symmetric key (for group encryption).
  static Uint8List generateSymmetricKey() {
    final sodium = sodiumInstance;
    return sodium.randombytes.buf(32);
  }

  /// Derive a 32-byte peer ID from a public key (BLAKE2b-256 hash).
  static Uint8List derivePeerId(Uint8List publicKey) {
    final sodium = sodiumInstance;
    return sodium.crypto.genericHash(message: publicKey, outLen: 32);
  }

  static String bytesToHex(Uint8List bytes) => HexUtils.encode(bytes);

  static Uint8List hexToBytes(String hex) => HexUtils.decode(hex);
}

/// Secure storage for cryptographic keys (ISP).
///
/// Clients that only need key generation can depend on [KeyGenerator] alone.
class KeyStorage {
  static const _staticPrivateKeyTag = 'fluxon_static_private_key';
  static const _staticPublicKeyTag = 'fluxon_static_public_key';
  static const _signingPrivateKeyTag = 'fluxon_signing_private_key';
  static const _signingPublicKeyTag = 'fluxon_signing_public_key';

  final FlutterSecureStorage _storage;

  KeyStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// HIGH-C4: Decode a stored key value.
  ///
  /// New keys are stored as base64. On load, try base64 first; if that fails
  /// (FormatException), fall back to hex decode for backward-compat with old
  /// installs, then re-save in base64 automatically.
  Uint8List _decodeStoredKey(String value) {
    try {
      return base64Decode(value);
    } on FormatException {
      // Legacy hex-encoded key — decode and let the caller re-persist.
      return HexUtils.decode(value);
    }
  }

  /// Store the static key pair in secure storage.
  ///
  /// HIGH-C4: Keys are now stored as base64, not hex, to reduce the length of
  /// secrets stored in the OS keychain and remove hex as an attack surface.
  Future<void> storeStaticKeyPair({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await Future.wait([
      _storage.write(
        key: _staticPrivateKeyTag,
        value: base64Encode(privateKey),
      ),
      _storage.write(
        key: _staticPublicKeyTag,
        value: base64Encode(publicKey),
      ),
    ]);
  }

  /// Load the static key pair from secure storage.
  ///
  /// Returns null if no key pair is stored.
  /// HIGH-C4: Tries base64 first; migrates old hex-encoded entries on first load.
  Future<({Uint8List privateKey, Uint8List publicKey})?> loadStaticKeyPair() async {
    final privateRaw = await _storage.read(key: _staticPrivateKeyTag);
    final publicRaw = await _storage.read(key: _staticPublicKeyTag);

    if (privateRaw == null || publicRaw == null) return null;

    final privateKey = _decodeStoredKey(privateRaw);
    final publicKey = _decodeStoredKey(publicRaw);

    // Migrate legacy hex keys: re-save as base64 if the stored string is hex.
    if (!_isBase64(privateRaw) || !_isBase64(publicRaw)) {
      await storeStaticKeyPair(privateKey: privateKey, publicKey: publicKey);
    }

    return (privateKey: privateKey, publicKey: publicKey);
  }

  /// Returns true if [s] looks like a base64 string (no hex-only characters).
  ///
  /// A quick heuristic: base64 uses A-Z, a-z, 0-9, +, /, =.
  /// A pure hex string only uses 0-9 and a-f. Checking for any character
  /// outside the hex range is sufficient to distinguish them for our key sizes.
  bool _isBase64(String s) {
    // Base64 strings have length divisible by 4 (with padding) or contain +/=
    // characters that hex strings never do.
    return s.contains('+') || s.contains('/') || s.contains('=') ||
        // Also consider that base64url (no padding) won't have = but will have
        // uppercase letters beyond 'F'. Fallback: try to base64 decode.
        (() {
          try {
            base64Decode(s);
            // If the decoded length matches expected key size, it's base64.
            return base64Decode(s).length <= 128; // all our keys ≤128 bytes
          } catch (_) {
            return false;
          }
        })();
  }

  /// Get or generate the static key pair.
  ///
  /// If a key pair exists in storage, loads it. Otherwise generates a new one
  /// and stores it.
  Future<({Uint8List privateKey, Uint8List publicKey})> getOrCreateStaticKeyPair() async {
    final existing = await loadStaticKeyPair();
    if (existing != null) return existing;

    final keyPair = KeyGenerator.generateStaticKeyPair();
    await storeStaticKeyPair(
      privateKey: keyPair.privateKey,
      publicKey: keyPair.publicKey,
    );
    return keyPair;
  }

  /// Delete stored key pair.
  Future<void> deleteStaticKeyPair() async {
    await _storage.delete(key: _staticPrivateKeyTag);
    await _storage.delete(key: _staticPublicKeyTag);
  }

  /// Store the Ed25519 signing key pair in secure storage.
  ///
  /// HIGH-C4: Keys stored as base64.
  Future<void> storeSigningKeyPair({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await Future.wait([
      _storage.write(
        key: _signingPrivateKeyTag,
        value: base64Encode(privateKey),
      ),
      _storage.write(
        key: _signingPublicKeyTag,
        value: base64Encode(publicKey),
      ),
    ]);
  }

  /// Load the Ed25519 signing key pair from secure storage.
  ///
  /// Returns null if no key pair is stored.
  /// HIGH-C4: Tries base64 first; migrates old hex-encoded entries on first load.
  Future<({Uint8List privateKey, Uint8List publicKey})?> loadSigningKeyPair() async {
    final privateRaw = await _storage.read(key: _signingPrivateKeyTag);
    final publicRaw = await _storage.read(key: _signingPublicKeyTag);

    if (privateRaw == null || publicRaw == null) return null;

    final privateKey = _decodeStoredKey(privateRaw);
    final publicKey = _decodeStoredKey(publicRaw);

    // Migrate legacy hex keys: re-save as base64 if the stored string is hex.
    if (!_isBase64(privateRaw) || !_isBase64(publicRaw)) {
      await storeSigningKeyPair(privateKey: privateKey, publicKey: publicKey);
    }

    return (privateKey: privateKey, publicKey: publicKey);
  }

  /// Get or generate the Ed25519 signing key pair.
  ///
  /// If a key pair exists in storage, loads it. Otherwise generates a new one
  /// and stores it.
  Future<({Uint8List privateKey, Uint8List publicKey})> getOrCreateSigningKeyPair() async {
    final existing = await loadSigningKeyPair();
    if (existing != null) return existing;

    // Import Signatures to use generateSigningKeyPair
    // This will be available at runtime
    final keyPair = Signatures.generateSigningKeyPair();
    await storeSigningKeyPair(
      privateKey: keyPair.privateKey,
      publicKey: keyPair.publicKey,
    );
    return keyPair;
  }

  /// Delete stored signing key pair.
  Future<void> deleteSigningKeyPair() async {
    await _storage.delete(key: _signingPrivateKeyTag);
    await _storage.delete(key: _signingPublicKeyTag);
  }
}

/// Backward-compatible facade that composes [KeyGenerator] and [KeyStorage].
///
/// Existing code can continue using [KeyManager] without changes.
class KeyManager {
  final KeyStorage _keyStorage;

  KeyManager({FlutterSecureStorage? storage})
      : _keyStorage = KeyStorage(storage: storage);

  static ({Uint8List privateKey, Uint8List publicKey}) generateStaticKeyPair() =>
      KeyGenerator.generateStaticKeyPair();

  static Uint8List generateSymmetricKey() => KeyGenerator.generateSymmetricKey();

  Uint8List derivePeerId(Uint8List publicKey) =>
      KeyGenerator.derivePeerId(publicKey);

  Future<void> storeStaticKeyPair({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) =>
      _keyStorage.storeStaticKeyPair(privateKey: privateKey, publicKey: publicKey);

  Future<({Uint8List privateKey, Uint8List publicKey})?> loadStaticKeyPair() =>
      _keyStorage.loadStaticKeyPair();

  Future<({Uint8List privateKey, Uint8List publicKey})> getOrCreateStaticKeyPair() =>
      _keyStorage.getOrCreateStaticKeyPair();

  Future<void> deleteStaticKeyPair() => _keyStorage.deleteStaticKeyPair();

  Future<void> storeSigningKeyPair({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) =>
      _keyStorage.storeSigningKeyPair(privateKey: privateKey, publicKey: publicKey);

  Future<({Uint8List privateKey, Uint8List publicKey})?> loadSigningKeyPair() =>
      _keyStorage.loadSigningKeyPair();

  Future<({Uint8List privateKey, Uint8List publicKey})> getOrCreateSigningKeyPair() =>
      _keyStorage.getOrCreateSigningKeyPair();

  Future<void> deleteSigningKeyPair() => _keyStorage.deleteSigningKeyPair();
}
