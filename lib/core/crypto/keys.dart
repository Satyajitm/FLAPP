import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium_libs/sodium_libs.dart';

/// Pure key generation logic — no storage dependencies (ISP).
class KeyGenerator {
  /// Generate a new Curve25519 static key pair.
  ///
  /// Returns (privateKey, publicKey) as raw 32-byte arrays.
  static ({Uint8List privateKey, Uint8List publicKey}) generateStaticKeyPair() {
    final sodium = SodiumInit.sodium;
    final keyPair = sodium.crypto.box.keyPair();
    return (
      privateKey: keyPair.secretKey.extractBytes(),
      publicKey: Uint8List.fromList(keyPair.publicKey),
    );
  }

  /// Generate a random 32-byte symmetric key (for group encryption).
  static Uint8List generateSymmetricKey() {
    final sodium = SodiumInit.sodium;
    return sodium.randombytes.buf(32);
  }

  /// Derive a 32-byte peer ID from a public key (SHA-256 hash).
  static Uint8List derivePeerId(Uint8List publicKey) {
    final sodium = SodiumInit.sodium;
    return sodium.crypto.genericHash(message: publicKey, outLen: 32);
  }

  static String bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List hexToBytes(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}

/// Secure storage for cryptographic keys (ISP).
///
/// Clients that only need key generation can depend on [KeyGenerator] alone.
class KeyStorage {
  static const _staticPrivateKeyTag = 'fluxon_static_private_key';
  static const _staticPublicKeyTag = 'fluxon_static_public_key';

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

  static Uint8List derivePeerId(Uint8List publicKey) =>
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
}
