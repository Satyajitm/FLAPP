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

  /// Derive a 32-byte peer ID from a public key (SHA-256 hash).
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

  /// Store the static key pair in secure storage.
  Future<void> storeStaticKeyPair({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await _storage.write(
      key: _staticPrivateKeyTag,
      value: KeyGenerator.bytesToHex(privateKey),
    );
    await _storage.write(
      key: _staticPublicKeyTag,
      value: KeyGenerator.bytesToHex(publicKey),
    );
  }

  /// Load the static key pair from secure storage.
  ///
  /// Returns null if no key pair is stored.
  Future<({Uint8List privateKey, Uint8List publicKey})?> loadStaticKeyPair() async {
    final privateHex = await _storage.read(key: _staticPrivateKeyTag);
    final publicHex = await _storage.read(key: _staticPublicKeyTag);

    if (privateHex == null || publicHex == null) return null;

    return (
      privateKey: KeyGenerator.hexToBytes(privateHex),
      publicKey: KeyGenerator.hexToBytes(publicHex),
    );
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
  Future<void> storeSigningKeyPair({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    await _storage.write(
      key: _signingPrivateKeyTag,
      value: KeyGenerator.bytesToHex(privateKey),
    );
    await _storage.write(
      key: _signingPublicKeyTag,
      value: KeyGenerator.bytesToHex(publicKey),
    );
  }

  /// Load the Ed25519 signing key pair from secure storage.
  ///
  /// Returns null if no key pair is stored.
  Future<({Uint8List privateKey, Uint8List publicKey})?> loadSigningKeyPair() async {
    final privateHex = await _storage.read(key: _signingPrivateKeyTag);
    final publicHex = await _storage.read(key: _signingPublicKeyTag);

    if (privateHex == null || publicHex == null) return null;

    return (
      privateKey: KeyGenerator.hexToBytes(privateHex),
      publicKey: KeyGenerator.hexToBytes(publicHex),
    );
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
