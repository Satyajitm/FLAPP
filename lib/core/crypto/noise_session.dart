import 'dart:typed_data';
import 'noise_protocol.dart';

/// A completed Noise session with transport-level encryption.
///
/// Created after a successful Noise XX handshake. Provides encrypt/decrypt
/// for application messages, with automatic nonce management and replay
/// protection via the underlying CipherState.
class NoiseSession {
  final NoiseCipherState _sendCipher;
  final NoiseCipherState _receiveCipher;
  final Uint8List handshakeHash;
  final Uint8List remotePeerId;

  /// Message counter for re-keying threshold.
  int _messagesSent = 0;
  int _messagesReceived = 0;

  /// Re-key after this many messages (configurable).
  static const int rekeyThreshold = 1000000;

  NoiseSession({
    required NoiseCipherState sendCipher,
    required NoiseCipherState receiveCipher,
    required this.handshakeHash,
    required this.remotePeerId,
  })  : _sendCipher = sendCipher,
        _receiveCipher = receiveCipher;

  /// Create a session from a completed handshake.
  factory NoiseSession.fromHandshake(
    NoiseHandshakeState handshake, {
    required Uint8List remotePeerId,
  }) {
    final ciphers = handshake.getTransportCiphers();
    return NoiseSession(
      sendCipher: ciphers.send,
      receiveCipher: ciphers.receive,
      handshakeHash: ciphers.handshakeHash,
      remotePeerId: remotePeerId,
    );
  }

  /// Encrypt a message for the remote peer.
  ///
  /// MED-C2: Increment the counter only after the encrypt call succeeds
  /// so that a failed encryption doesn't advance the rekey threshold.
  Uint8List encrypt(Uint8List plaintext) {
    final result = _sendCipher.encrypt(plaintext);
    _messagesSent++;
    return result;
  }

  /// Decrypt a message from the remote peer.
  Uint8List decrypt(Uint8List ciphertext) {
    final plaintext = _receiveCipher.decrypt(ciphertext);
    _messagesReceived++;
    return plaintext;
  }

  /// Whether this session should be re-keyed.
  bool get shouldRekey =>
      _messagesSent >= rekeyThreshold || _messagesReceived >= rekeyThreshold;

  /// Destroy this session's cryptographic state.
  void dispose() {
    _sendCipher.clear();
    _receiveCipher.clear();
  }
}
