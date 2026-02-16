import 'dart:typed_data';
import '../../shared/logger.dart';
import 'noise_protocol.dart';
import 'noise_session.dart';

/// Manages Noise XX handshake state machines and post-handshake sessions.
///
/// Keyed by BLE device ID (platform string like MAC address), not by Fluxon peer ID.
/// This is because the BLE device ID is the only identity available before the handshake
/// completes and reveals the remote peer's static public key.
class NoiseSessionManager {
  final Uint8List _myStaticPrivKey;
  final Uint8List _myStaticPubKey;

  /// Pending handshakes in progress, keyed by BLE device ID.
  final Map<String, NoiseHandshakeState> _pendingHandshakes = {};

  /// Completed sessions, keyed by BLE device ID.
  final Map<String, NoiseSession> _sessions = {};

  NoiseSessionManager({
    required Uint8List myStaticPrivKey,
    required Uint8List myStaticPubKey,
  })  : _myStaticPrivKey = myStaticPrivKey,
        _myStaticPubKey = myStaticPubKey;

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
    _pendingHandshakes[deviceId] = state;

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
  ({Uint8List? response, Uint8List? remotePubKey}) processHandshakeMessage(
    String deviceId,
    Uint8List messageBytes,
  ) {
    // If we have no pending state, this must be message 1 from a remote central (we're responder).
    if (!_pendingHandshakes.containsKey(deviceId)) {
      final state = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: _myStaticPrivKey,
        localStaticPublicKey: _myStaticPubKey,
      );

      state.readMessage(messageBytes); // <- e
      final message2 = state.writeMessage(); // -> e, ee, s, es

      _pendingHandshakes[deviceId] = state;

      SecureLogger.debug(
        '[NoiseSessionManager] Received handshake message 1 from $deviceId, '
        'responding as responder',
      );

      return (response: message2, remotePubKey: null);
    }

    final state = _pendingHandshakes[deviceId]!;

    // Process based on current role and handshake progress.
    if (state.role == NoiseRole.initiator) {
      // Initiator receiving message 2: <- e, ee, s, es
      state.readMessage(messageBytes);
      final message3 = state.writeMessage(); // -> s, se

      if (state.isComplete) {
        final remotePubKey = state.remoteStaticPublic;
        if (remotePubKey != null) {
          final session = NoiseSession.fromHandshake(
            state,
            remotePeerId: remotePubKey,
          );
          _sessions[deviceId] = session;
          _pendingHandshakes.remove(deviceId);

          SecureLogger.debug(
            '[NoiseSessionManager] Initiator handshake complete for $deviceId, session established',
          );

          return (response: message3, remotePubKey: remotePubKey);
        }
      }

      return (response: message3, remotePubKey: null);
    } else {
      // Responder receiving message 3: -> s, se
      state.readMessage(messageBytes);

      if (state.isComplete) {
        final remotePubKey = state.remoteStaticPublic;
        if (remotePubKey != null) {
          final session = NoiseSession.fromHandshake(
            state,
            remotePeerId: remotePubKey,
          );
          _sessions[deviceId] = session;
          _pendingHandshakes.remove(deviceId);

          SecureLogger.debug(
            '[NoiseSessionManager] Responder handshake complete for $deviceId, session established',
          );

          return (response: null, remotePubKey: remotePubKey);
        }
      }

      return (response: null, remotePubKey: null);
    }
  }

  /// Check if a session is established for the given BLE device ID.
  bool hasSession(String deviceId) => _sessions.containsKey(deviceId);

  /// Encrypt plaintext using the established session for a given device.
  ///
  /// Returns null if no session exists for this device (packet should not be sent).
  Uint8List? encrypt(Uint8List plaintext, String deviceId) {
    final session = _sessions[deviceId];
    if (session == null) return null;
    return session.encrypt(plaintext);
  }

  /// Decrypt ciphertext using the established session for a given device.
  ///
  /// Returns null if no session exists or decryption fails (packet should be dropped).
  Uint8List? decrypt(Uint8List ciphertext, String deviceId) {
    final session = _sessions[deviceId];
    if (session == null) return null;

    try {
      return session.decrypt(ciphertext);
    } catch (e) {
      SecureLogger.warning('[NoiseSessionManager] Decryption failed for $deviceId: $e');
      return null;
    }
  }

  /// Remove the session for a given device (e.g., on BLE disconnect).
  void removeSession(String deviceId) {
    _sessions.remove(deviceId);
    _pendingHandshakes.remove(deviceId);
    SecureLogger.debug('[NoiseSessionManager] Removed session for $deviceId');
  }

  /// Get the remote peer's static public key (available after handshake).
  ///
  /// Returns null if handshake not complete.
  Uint8List? getRemotePubKey(String deviceId) {
    final state = _pendingHandshakes[deviceId];
    if (state != null && state.isComplete) {
      return state.remoteStaticPublic;
    }
    return null;
  }

  /// Clear all sessions and pending handshakes (e.g., on app shutdown).
  void clear() {
    _pendingHandshakes.clear();
    _sessions.forEach((_, session) => session.dispose());
    _sessions.clear();
  }
}
