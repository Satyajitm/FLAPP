import 'dart:collection';
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

  /// LRU cap for [_trustedPeers] — consistent with NoiseSessionManager and
  /// MeshService caps. Prevents write-amplification DoS via many ephemeral peers.
  static const int _maxTrustedPeers = 500;

  /// M3: LRU-ordered map of trusted peer IDs (peers we've completed handshakes with).
  ///
  /// Using [LinkedHashMap] preserves insertion order so the oldest entry can be
  /// evicted when the cap is reached. Persisted to flutter_secure_storage so
  /// trust survives app restarts (enables TOFU and peer blocklists).
  final LinkedHashMap<PeerId, bool> _trustedPeers = LinkedHashMap();

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
  ///
  /// If [peerId] is already trusted it is promoted to MRU position.
  /// If the cap of [_maxTrustedPeers] is reached, the least-recently-trusted
  /// peer is evicted to keep the set bounded.
  Future<void> trustPeer(PeerId peerId) async {
    if (_trustedPeers.containsKey(peerId)) {
      // Re-insert at end to promote to MRU position.
      _trustedPeers.remove(peerId);
    } else if (_trustedPeers.length >= _maxTrustedPeers) {
      // Evict LRU (first inserted) entry.
      _trustedPeers.remove(_trustedPeers.keys.first);
    }
    _trustedPeers[peerId] = true;
    await _persistTrustedPeers();
  }

  /// Remove trust for a peer.
  Future<void> revokeTrust(PeerId peerId) async {
    _trustedPeers.remove(peerId);
    await _persistTrustedPeers();
  }

  /// Check if a peer is trusted.
  bool isTrusted(PeerId peerId) => _trustedPeers.containsKey(peerId);

  /// All currently trusted peers (unmodifiable snapshot).
  Set<PeerId> get trustedPeers => Set.unmodifiable(_trustedPeers.keys.toSet());

  /// Reset identity (deletes keys and trust).
  Future<void> resetIdentity() async {
    await _keyManager.deleteStaticKeyPair();
    await _keyManager.deleteSigningKeyPair();
    try {
      await _secureStorage.delete(key: _trustedPeersKey);
    } catch (_) {
      // Non-fatal — in-memory set is cleared below.
    }
    // HIGH-N3: Zero private key bytes before nulling the reference so GC heap
    // pages holding the key bytes are overwritten rather than lingering until GC.
    if (_staticPrivateKey != null) {
      for (int i = 0; i < _staticPrivateKey!.length; i++) _staticPrivateKey![i] = 0;
    }
    if (_signingPrivateKey != null) {
      for (int i = 0; i < _signingPrivateKey!.length; i++) _signingPrivateKey![i] = 0;
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
      // M13: Only iterate up to _maxTrustedPeers entries to prevent unbounded
      // heap growth from a corrupt/crafted storage value.
      for (final hex in hexList.take(_maxTrustedPeers)) {
        if (hex is String) {
          try {
            _trustedPeers[PeerId.fromHex(hex)] = true;
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
      final hexList = _trustedPeers.keys.map((p) => p.hex).toList();
      await _secureStorage.write(
        key: _trustedPeersKey,
        value: jsonEncode(hexList),
      );
    } catch (_) {
      // Non-fatal — in-memory set is still correct for this session.
    }
  }
}
