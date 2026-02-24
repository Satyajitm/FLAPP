import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../crypto/keys.dart';
import 'peer_id.dart';

/// Manages the local device's identity and trust for remote peers.
///
/// Ported from Bitchat's SecureIdentityStateManager.
class IdentityManager {
  final KeyManager _keyManager;
  static const _secureStorage = FlutterSecureStorage();
  static const _trustedPeersKey = 'trusted_peers_v1';

  Uint8List? _staticPrivateKey;
  Uint8List? _staticPublicKey;
  Uint8List? _signingPrivateKey;
  Uint8List? _signingPublicKey;
  PeerId? _myPeerId;

  /// M3: Set of trusted peer IDs (peers we've completed handshakes with).
  /// Persisted to flutter_secure_storage so trust survives app restarts
  /// (enables TOFU and peer blocklists across sessions).
  final Set<PeerId> _trustedPeers = {};

  IdentityManager({KeyManager? keyManager})
      : _keyManager = keyManager ?? KeyManager();

  /// Initialize the identity (loads or creates static and signing key pairs).
  Future<void> initialize() async {
    final keyPair = await _keyManager.getOrCreateStaticKeyPair();
    _staticPrivateKey = keyPair.privateKey;
    _staticPublicKey = keyPair.publicKey;
    _myPeerId = PeerId(_keyManager.derivePeerId(_staticPublicKey!));

    final signingKeyPair = await _keyManager.getOrCreateSigningKeyPair();
    _signingPrivateKey = signingKeyPair.privateKey;
    _signingPublicKey = signingKeyPair.publicKey;

    await _loadTrustedPeers();
  }

  /// This device's peer ID.
  PeerId get myPeerId {
    if (_myPeerId == null) throw StateError('IdentityManager not initialized');
    return _myPeerId!;
  }

  /// This device's static public key (32 bytes).
  Uint8List get publicKey {
    if (_staticPublicKey == null) throw StateError('IdentityManager not initialized');
    return _staticPublicKey!;
  }

  /// This device's static private key (32 bytes).
  Uint8List get privateKey {
    if (_staticPrivateKey == null) throw StateError('IdentityManager not initialized');
    return _staticPrivateKey!;
  }

  /// This device's Ed25519 signing private key (64 bytes).
  Uint8List get signingPrivateKey {
    if (_signingPrivateKey == null) throw StateError('IdentityManager not initialized');
    return _signingPrivateKey!;
  }

  /// This device's Ed25519 signing public key (32 bytes).
  Uint8List get signingPublicKey {
    if (_signingPublicKey == null) throw StateError('IdentityManager not initialized');
    return _signingPublicKey!;
  }

  /// Mark a peer as trusted (after successful handshake).
  Future<void> trustPeer(PeerId peerId) async {
    _trustedPeers.add(peerId);
    await _persistTrustedPeers();
  }

  /// Remove trust for a peer.
  Future<void> revokeTrust(PeerId peerId) async {
    _trustedPeers.remove(peerId);
    await _persistTrustedPeers();
  }

  /// Check if a peer is trusted.
  bool isTrusted(PeerId peerId) => _trustedPeers.contains(peerId);

  /// All currently trusted peers.
  Set<PeerId> get trustedPeers => Set.unmodifiable(_trustedPeers);

  /// Reset identity (deletes keys and trust).
  Future<void> resetIdentity() async {
    await _keyManager.deleteStaticKeyPair();
    await _keyManager.deleteSigningKeyPair();
    try {
      await _secureStorage.delete(key: _trustedPeersKey);
    } catch (_) {
      // Non-fatal — in-memory set is cleared below.
    }
    _staticPrivateKey = null;
    _staticPublicKey = null;
    _signingPrivateKey = null;
    _signingPublicKey = null;
    _myPeerId = null;
    _trustedPeers.clear();
  }

  /// Load trusted peers from secure storage.
  Future<void> _loadTrustedPeers() async {
    try {
      final stored = await _secureStorage.read(key: _trustedPeersKey);
      if (stored == null || stored.isEmpty) return;
      final List<dynamic> hexList = jsonDecode(stored) as List<dynamic>;
      for (final hex in hexList) {
        if (hex is String) {
          try {
            _trustedPeers.add(PeerId.fromHex(hex));
          } catch (_) {
            // Skip malformed entries.
          }
        }
      }
    } catch (_) {
      // Corrupt or missing — start with empty trust set.
    }
  }

  /// Persist the trusted peer set to secure storage.
  Future<void> _persistTrustedPeers() async {
    try {
      final hexList = _trustedPeers.map((p) => p.hex).toList();
      await _secureStorage.write(
        key: _trustedPeersKey,
        value: jsonEncode(hexList),
      );
    } catch (_) {
      // Non-fatal — in-memory set is still correct for this session.
    }
  }
}
