import 'dart:collection';
import 'dart:typed_data';
import '../../shared/logger.dart';
import 'noise_protocol.dart';
import 'noise_session.dart';

/// Per-peer state consolidated from what was previously four separate maps.
class _PeerState {
  NoiseHandshakeState? handshake;
  NoiseSession? session;
  Uint8List? signingKey;

  /// Remote static public key — stored after handshake completes so it remains
  /// accessible via [NoiseSessionManager.getRemotePubKey] after [handshake] is nulled.
  Uint8List? remoteStaticPublicKey;

  int lastHandshakeTime;
  int handshakeAttempts;

  _PeerState({
    this.handshake,
    this.session,
    this.signingKey,
    this.remoteStaticPublicKey,
    this.lastHandshakeTime = 0,
    this.handshakeAttempts = 0,
  });
}

/// Manages Noise XX handshake state machines and post-handshake sessions.
///
/// Keyed by BLE device ID (platform string like MAC address), not by Fluxon peer ID.
/// This is because the BLE device ID is the only identity available before the handshake
/// completes and reveals the remote peer's static public key.
class NoiseSessionManager {
  final Uint8List _myStaticPrivKey;
  final Uint8List _myStaticPubKey;
  final Uint8List _localSigningPublicKey;

  /// Per-peer state, keyed by BLE device ID.
  /// LRU-ordered (LinkedHashMap insertion order): oldest entry evicted at [_maxPeers].
  final LinkedHashMap<String, _PeerState> _peers = LinkedHashMap();

  /// Maximum number of peer entries to keep in memory.
  /// Protects against unbounded map growth from device-ID-cycling attacks.
  static const _maxPeers = 500;

  /// MED-3: Global handshake rate limit across all devices.
  /// Prevents CPU exhaustion via MAC-rotation attacks (X25519 DH per handshake).
  int _globalHandshakeCount = 0;
  int _globalHandshakeWindowStart = 0;
  static const _maxGlobalHandshakesPerMinute = 20;

  NoiseSessionManager({
    required Uint8List myStaticPrivKey,
    required Uint8List myStaticPubKey,
    required Uint8List localSigningPublicKey,
  })  : _myStaticPrivKey = myStaticPrivKey,
        _myStaticPubKey = myStaticPubKey,
        _localSigningPublicKey = localSigningPublicKey;

  /// Get or create state for a device. Marks the entry as recently used (LRU).
  _PeerState _stateFor(String deviceId) {
    // Re-insert to mark as recently used.
    final existing = _peers.remove(deviceId);
    final state = existing ?? _PeerState();
    _peers[deviceId] = state;

    // Evict oldest entry if over the limit.
    while (_peers.length > _maxPeers) {
      _peers.remove(_peers.keys.first);
    }

    return state;
  }

  /// Start a Noise XX handshake as the initiator (central role).
  ///
  /// Should be called immediately after a BLE central connects to a peripheral.
  /// Returns the raw Noise message bytes (message 1: `e`) to send as the payload
  /// of a [MessageType.handshake] packet.
  Uint8List startHandshake(String deviceId) {
    final state = NoiseHandshakeState(
      role: NoiseRole.initiator,
      localStaticPrivateKey: _myStaticPrivKey,
      localStaticPublicKey: _myStaticPubKey,
    );

    final message1 = state.writeMessage(); // -> e
    _stateFor(deviceId).handshake = state;

    SecureLogger.debug('[NoiseSessionManager] Started handshake as initiator for $deviceId');
    return message1;
  }

  /// Process an incoming Noise handshake message.
  ///
  /// Call this whenever a [MessageType.handshake] packet is received from a peer.
  /// The peer's BLE device ID and the raw Noise message bytes are required.
  ///
  /// Returns:
  /// - `response`: the Noise message to send back (null if no response needed)
  /// - `remotePubKey`: the remote peer's static public key after handshake completion
  ///   (non-null only when `handshakeState.isComplete` becomes true)
  /// - `remoteSigningPublicKey`: the remote peer's Ed25519 signing public key after
  ///   handshake completion (non-null only when `handshakeState.isComplete` becomes true)
  ({Uint8List? response, Uint8List? remotePubKey, Uint8List? remoteSigningPublicKey}) processHandshakeMessage(
    String deviceId,
    Uint8List messageBytes,
  ) {
    // Rate-limit incoming handshake attempts to prevent replay / DoS attacks.
    final now = DateTime.now().millisecondsSinceEpoch;

    // MED-3: Global handshake rate limit (max 20 per minute across all devices).
    if (now - _globalHandshakeWindowStart >= 60000) {
      _globalHandshakeCount = 0;
      _globalHandshakeWindowStart = now;
    }
    _globalHandshakeCount++;
    if (_globalHandshakeCount > _maxGlobalHandshakesPerMinute) {
      SecureLogger.warning(
        '[NoiseSessionManager] Global handshake rate limit exceeded — dropping',
      );
      return (response: null, remotePubKey: null, remoteSigningPublicKey: null);
    }

    final peer = _stateFor(deviceId);

    if (now - peer.lastHandshakeTime < 60000) {
      peer.handshakeAttempts++;
      if (peer.handshakeAttempts > 5) return (response: null, remotePubKey: null, remoteSigningPublicKey: null); // Rate limit
    } else {
      peer.handshakeAttempts = 1;
    }
    peer.lastHandshakeTime = now;

    // If we have no pending state, this must be message 1 from a remote central (we're responder).
    if (peer.handshake == null) {
      final state = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: _myStaticPrivKey,
        localStaticPublicKey: _myStaticPubKey,
      );

      try {
        state.readMessage(messageBytes); // <- e
        // Include our signing public key as payload in message 2 (AEAD-encrypted via es DH)
        final message2 = state.writeMessage(payload: _localSigningPublicKey); // -> e, ee, s, es

        peer.handshake = state;

        SecureLogger.debug(
          '[NoiseSessionManager] Received handshake message 1 from $deviceId, '
          'responding as responder',
        );

        return (response: message2, remotePubKey: null, remoteSigningPublicKey: null);
      } catch (e) {
        // CRIT-4: Dispose ephemeral keys on any failure path.
        state.dispose();
        rethrow;
      }
    }

    final state = peer.handshake!;

    // CRIT-4: Use try/finally to ensure handshake state is always disposed on
    // any error path, preventing ephemeral key material from lingering in heap.
    try {
      // Process based on current role and handshake progress.
      if (state.role == NoiseRole.initiator) {
        // Initiator receiving message 2: <- e, ee, s, es (with remote signing key as payload)
        final remoteSigningKey = state.readMessage(messageBytes); // returns decrypted payload
        // Include our signing public key as payload in message 3 (AEAD-encrypted via se DH)
        final message3 = state.writeMessage(payload: _localSigningPublicKey); // -> s, se

        if (state.isComplete) {
          final remotePubKey = state.remoteStaticPublic;
          if (remotePubKey != null && remoteSigningKey.isNotEmpty && remoteSigningKey.length == 32) {
            if (remoteSigningKey.every((b) => b == 0)) {
              throw Exception('Invalid signing key: all-zero key rejected');
            }
            peer.signingKey = remoteSigningKey;
            peer.remoteStaticPublicKey = remotePubKey;

            final session = NoiseSession.fromHandshake(
              state,
              remotePeerId: remotePubKey,
            );
            peer.session = session;
            peer.handshake = null;
            state.dispose(); // CRIT-4: Zero ephemeral keys after session extraction

            SecureLogger.debug(
              '[NoiseSessionManager] Initiator handshake complete for $deviceId, session established',
            );

            return (response: message3, remotePubKey: remotePubKey, remoteSigningPublicKey: remoteSigningKey);
          }
        }

        return (response: message3, remotePubKey: null, remoteSigningPublicKey: null);
      } else {
        // Responder receiving message 3: -> s, se (with remote signing key as payload)
        final remoteSigningKey = state.readMessage(messageBytes); // returns decrypted payload

        if (state.isComplete) {
          final remotePubKey = state.remoteStaticPublic;
          if (remotePubKey != null && remoteSigningKey.isNotEmpty && remoteSigningKey.length == 32) {
            if (remoteSigningKey.every((b) => b == 0)) {
              throw Exception('Invalid signing key: all-zero key rejected');
            }
            peer.signingKey = remoteSigningKey;
            peer.remoteStaticPublicKey = remotePubKey;

            final session = NoiseSession.fromHandshake(
              state,
              remotePeerId: remotePubKey,
            );
            peer.session = session;
            peer.handshake = null;
            state.dispose(); // CRIT-4: Zero ephemeral keys after session extraction

            SecureLogger.debug(
              '[NoiseSessionManager] Responder handshake complete for $deviceId, session established',
            );

            return (response: null, remotePubKey: remotePubKey, remoteSigningPublicKey: remoteSigningKey);
          }
        }

        return (response: null, remotePubKey: null, remoteSigningPublicKey: null);
      }
    } catch (e) {
      // CRIT-4: Dispose handshake state on any failure to zero ephemeral keys.
      peer.handshake?.dispose();
      peer.handshake = null;
      rethrow;
    }
  }

  /// Check if a session is established for the given BLE device ID.
  bool hasSession(String deviceId) => _peers[deviceId]?.session != null;

  /// Encrypt plaintext using the established session for a given device.
  ///
  /// Returns null if no session exists for this device (packet should not be sent).
  /// C6: Checks [NoiseSession.shouldRekey] and tears down the session if re-keying is needed.
  Uint8List? encrypt(Uint8List plaintext, String deviceId) {
    final peer = _peers[deviceId];
    final session = peer?.session;
    if (session == null) return null;

    // C6: Tear down sessions that have exceeded the re-key threshold so the
    // caller will re-initiate a fresh Noise XX handshake.
    if (session.shouldRekey) {
      SecureLogger.warning(
        '[NoiseSessionManager] Session for $deviceId needs re-key — tearing down',
      );
      session.dispose();
      peer!.session = null;
      return null;
    }

    return session.encrypt(plaintext);
  }

  /// Decrypt ciphertext using the established session for a given device.
  ///
  /// Returns null if no session exists or decryption fails (packet should be dropped).
  /// C6: Checks [NoiseSession.shouldRekey] after decryption.
  Uint8List? decrypt(Uint8List ciphertext, String deviceId) {
    final peer = _peers[deviceId];
    final session = peer?.session;
    if (session == null) return null;

    try {
      final plaintext = session.decrypt(ciphertext);

      // C6: Tear down sessions that have exceeded the re-key threshold.
      if (session.shouldRekey) {
        SecureLogger.warning(
          '[NoiseSessionManager] Session for $deviceId needs re-key — tearing down',
        );
        session.dispose();
        peer!.session = null;
      }

      return plaintext;
    } catch (e) {
      SecureLogger.warning('[NoiseSessionManager] Decryption failed for $deviceId: $e');
      return null;
    }
  }

  /// Remove the session for a given device (e.g., on BLE disconnect).
  void removeSession(String deviceId) {
    _peers.remove(deviceId);
    SecureLogger.debug('[NoiseSessionManager] Removed session for $deviceId');
  }

  /// Get the remote peer's static public key (available after handshake completes).
  ///
  /// Returns null if handshake has not completed for this device.
  Uint8List? getRemotePubKey(String deviceId) => _peers[deviceId]?.remoteStaticPublicKey;

  /// Get the remote peer's Ed25519 signing public key (available after handshake).
  ///
  /// Returns null if signing key not yet received.
  Uint8List? getSigningPublicKey(String deviceId) => _peers[deviceId]?.signingKey;

  /// Clear all sessions and pending handshakes (e.g., on app shutdown).
  void clear() {
    for (final peer in _peers.values) {
      peer.session?.dispose();
    }
    _peers.clear();
  }
}
