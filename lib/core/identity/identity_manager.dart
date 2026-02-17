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
  Uint8List? _signingPrivateKey;
  Uint8List? _signingPublicKey;
  PeerId? _myPeerId;

  /// Set of trusted peer IDs (peers we've completed handshakes with).
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
    await _keyManager.deleteSigningKeyPair();
    _staticPrivateKey = null;
    _staticPublicKey = null;
    _signingPrivateKey = null;
    _signingPublicKey = null;
    _myPeerId = null;
    _trustedPeers.clear();
  }
}
