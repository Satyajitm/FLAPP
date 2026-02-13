import 'dart:typed_data';
import '../crypto/keys.dart';
import 'peer_id.dart';

/// Manages the local device's identity and trust for remote peers.
///
/// Ported from Bitchat's SecureIdentityStateManager.
class IdentityManager {
  final KeyManager _keyManager;

  Uint8List? _staticPrivateKey;
  Uint8List? _staticPublicKey;
  PeerId? _myPeerId;

  /// Set of trusted peer IDs (peers we've completed handshakes with).
  final Set<PeerId> _trustedPeers = {};

  IdentityManager({KeyManager? keyManager})
      : _keyManager = keyManager ?? KeyManager();

  /// Initialize the identity (loads or creates static key pair).
  Future<void> initialize() async {
    final keyPair = await _keyManager.getOrCreateStaticKeyPair();
    _staticPrivateKey = keyPair.privateKey;
    _staticPublicKey = keyPair.publicKey;
    _myPeerId = PeerId(KeyManager.derivePeerId(_staticPublicKey!));
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

  /// Mark a peer as trusted (after successful handshake).
  void trustPeer(PeerId peerId) {
    _trustedPeers.add(peerId);
  }

  /// Remove trust for a peer.
  void revokeTrust(PeerId peerId) {
    _trustedPeers.remove(peerId);
  }

  /// Check if a peer is trusted.
  bool isTrusted(PeerId peerId) => _trustedPeers.contains(peerId);

  /// All currently trusted peers.
  Set<PeerId> get trustedPeers => Set.unmodifiable(_trustedPeers);

  /// Reset identity (deletes keys and trust).
  Future<void> resetIdentity() async {
    await _keyManager.deleteStaticKeyPair();
    _staticPrivateKey = null;
    _staticPublicKey = null;
    _myPeerId = null;
    _trustedPeers.clear();
  }
}
