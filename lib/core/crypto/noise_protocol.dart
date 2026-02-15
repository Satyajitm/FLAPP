import 'dart:convert';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';
import 'sodium_instance.dart';

/// Noise Protocol errors.
enum NoiseError {
  uninitializedCipher,
  invalidCiphertext,
  handshakeComplete,
  handshakeNotComplete,
  missingLocalStaticKey,
  missingKeys,
  invalidMessage,
  authenticationFailure,
  invalidPublicKey,
  replayDetected,
  nonceExceeded,
}

class NoiseException implements Exception {
  final NoiseError error;
  const NoiseException(this.error);

  @override
  String toString() => 'NoiseException: $error';
}

/// Noise handshake patterns.
enum NoisePattern {
  xx; // XX — mutual authentication, identity hiding

  List<List<NoiseMessageToken>> get messagePatterns {
    switch (this) {
      case NoisePattern.xx:
        return [
          [NoiseMessageToken.e], // -> e
          [NoiseMessageToken.e, NoiseMessageToken.ee, NoiseMessageToken.s, NoiseMessageToken.es], // <- e, ee, s, es
          [NoiseMessageToken.s, NoiseMessageToken.se], // -> s, se
        ];
    }
  }

  String get protocolName => 'Noise_XX_25519_ChaChaPoly_SHA256';
}

enum NoiseRole { initiator, responder }

enum NoiseMessageToken { e, s, ee, es, se, ss }

/// CipherState — manages symmetric encryption with nonce tracking.
///
/// Ported from Bitchat's NoiseCipherState using libsodium.
class NoiseCipherState {
  static const int nonceSize = 4;
  static const int replayWindowSize = 1024;
  static const int replayWindowBytes = replayWindowSize ~/ 8;
  static const int tagSize = 16; // Poly1305 tag

  SecureKey? _key;
  int _nonce = 0;
  final bool useExtractedNonce;

  // Sliding window replay protection
  int _highestReceivedNonce = 0;
  final Uint8List _replayWindow = Uint8List(replayWindowBytes);

  NoiseCipherState({this.useExtractedNonce = false});

  NoiseCipherState.withKey(SecureKey key, {this.useExtractedNonce = false})
      : _key = key;

  void initializeKey(SecureKey key) {
    _key = key;
    _nonce = 0;
  }

  bool get hasKey => _key != null;

  /// Encrypt plaintext with optional associated data.
  Uint8List encrypt(Uint8List plaintext, {Uint8List? ad}) {
    if (_key == null) throw const NoiseException(NoiseError.uninitializedCipher);
    if (_nonce > 0xFFFFFFFF) throw const NoiseException(NoiseError.nonceExceeded);

    final currentNonce = _nonce;

    // Build 12-byte nonce: 4 zero bytes + 8-byte big-endian counter (RFC 8439)
    final nonceData = Uint8List(12);
    final byteData = ByteData.sublistView(nonceData);
    byteData.setUint64(4, currentNonce, Endian.big);

    final sodium = sodiumInstance;
    final ciphertext = sodium.crypto.aeadChaCha20Poly1305.encrypt(
      message: plaintext,
      nonce: nonceData,
      key: _key!,
      additionalData: ad,
    );

    _nonce++;

    if (useExtractedNonce) {
      // Prepend 4-byte big-endian nonce
      final nonceBytes = Uint8List(nonceSize);
      ByteData.sublistView(nonceBytes).setUint32(0, currentNonce);
      final combined = Uint8List(nonceSize + ciphertext.length);
      combined.setAll(0, nonceBytes);
      combined.setAll(nonceSize, ciphertext);
      return combined;
    } else {
      return ciphertext;
    }
  }

  /// Decrypt ciphertext with optional associated data.
  Uint8List decrypt(Uint8List ciphertext, {Uint8List? ad}) {
    if (_key == null) throw const NoiseException(NoiseError.uninitializedCipher);
    if (ciphertext.length < tagSize) {
      throw const NoiseException(NoiseError.invalidCiphertext);
    }

    final int decryptionNonce;
    final Uint8List actualCiphertext;

    if (useExtractedNonce) {
      if (ciphertext.length < nonceSize + tagSize) {
        throw const NoiseException(NoiseError.invalidCiphertext);
      }
      decryptionNonce = ByteData.sublistView(ciphertext, 0, nonceSize).getUint32(0);
      actualCiphertext = Uint8List.sublistView(ciphertext, nonceSize);

      if (!_isValidNonce(decryptionNonce)) {
        throw const NoiseException(NoiseError.replayDetected);
      }
    } else {
      decryptionNonce = _nonce;
      actualCiphertext = ciphertext;
    }

    // Build 12-byte nonce (RFC 8439: 4 zero bytes + 8-byte big-endian counter)
    final nonceData = Uint8List(12);
    ByteData.sublistView(nonceData).setUint64(4, decryptionNonce, Endian.big);

    final sodium = sodiumInstance;
    try {
      final plaintext = sodium.crypto.aeadChaCha20Poly1305.decrypt(
        cipherText: actualCiphertext,
        nonce: nonceData,
        key: _key!,
        additionalData: ad,
      );

      if (useExtractedNonce) {
        _markNonceAsSeen(decryptionNonce);
      }
      _nonce++;

      return plaintext;
    } catch (_) {
      throw const NoiseException(NoiseError.invalidCiphertext);
    }
  }

  bool _isValidNonce(int receivedNonce) {
    if (_highestReceivedNonce >= replayWindowSize &&
        receivedNonce <= _highestReceivedNonce - replayWindowSize) {
      return false; // Too old
    }
    if (receivedNonce > _highestReceivedNonce) return true; // New

    final offset = _highestReceivedNonce - receivedNonce;
    final byteIndex = offset ~/ 8;
    final bitIndex = offset % 8;
    return (_replayWindow[byteIndex] & (1 << bitIndex)) == 0;
  }

  void _markNonceAsSeen(int receivedNonce) {
    if (receivedNonce > _highestReceivedNonce) {
      final shift = receivedNonce - _highestReceivedNonce;
      if (shift >= replayWindowSize) {
        _replayWindow.fillRange(0, replayWindowBytes, 0);
      } else {
        // Shift window right
        for (var i = replayWindowBytes - 1; i >= 0; i--) {
          final sourceIdx = i - shift ~/ 8;
          int newByte = 0;
          if (sourceIdx >= 0) {
            newByte = _replayWindow[sourceIdx] >> (shift % 8);
            if (sourceIdx > 0 && shift % 8 != 0) {
              newByte |= _replayWindow[sourceIdx - 1] << (8 - shift % 8);
            }
          }
          _replayWindow[i] = newByte & 0xFF;
        }
      }
      _highestReceivedNonce = receivedNonce;
      _replayWindow[0] |= 1;
    } else {
      final offset = _highestReceivedNonce - receivedNonce;
      _replayWindow[offset ~/ 8] |= (1 << (offset % 8));
    }
  }

  void clear() {
    _key?.dispose();
    _key = null;
    _nonce = 0;
    _highestReceivedNonce = 0;
    _replayWindow.fillRange(0, replayWindowBytes, 0);
  }
}

/// SymmetricState — handles key derivation and handshake hashing.
///
/// Ported from Bitchat's NoiseSymmetricState.
class NoiseSymmetricState {
  final NoiseCipherState _cipherState = NoiseCipherState();
  Uint8List _chainingKey;
  Uint8List _hash;

  NoiseSymmetricState(String protocolName) :
    _chainingKey = Uint8List(0),
    _hash = Uint8List(0) {
    final nameData = Uint8List.fromList(utf8.encode(protocolName));
    if (nameData.length <= 32) {
      _hash = Uint8List(32);
      _hash.setAll(0, nameData);
    } else {
      _hash = _sha256(nameData);
    }
    _chainingKey = Uint8List.fromList(_hash);
  }

  Uint8List get handshakeHash => Uint8List.fromList(_hash);

  void mixKey(Uint8List inputKeyMaterial) {
    final output = _hkdf(_chainingKey, inputKeyMaterial, 2);
    _chainingKey = output[0];
    final sodium = sodiumInstance;
    final tempKey = SecureKey.fromList(sodium, output[1]);
    _cipherState.initializeKey(tempKey);
  }

  void mixHash(Uint8List data) {
    final combined = Uint8List(_hash.length + data.length);
    combined.setAll(0, _hash);
    combined.setAll(_hash.length, data);
    _hash = _sha256(combined);
  }

  bool get hasCipherKey => _cipherState.hasKey;

  Uint8List encryptAndHash(Uint8List plaintext) {
    if (_cipherState.hasKey) {
      final ciphertext = _cipherState.encrypt(plaintext, ad: _hash);
      mixHash(ciphertext);
      return ciphertext;
    } else {
      mixHash(plaintext);
      return plaintext;
    }
  }

  Uint8List decryptAndHash(Uint8List ciphertext) {
    if (_cipherState.hasKey) {
      final plaintext = _cipherState.decrypt(ciphertext, ad: _hash);
      mixHash(ciphertext);
      return plaintext;
    } else {
      mixHash(ciphertext);
      return ciphertext;
    }
  }

  /// Split into two transport cipher states.
  (NoiseCipherState send, NoiseCipherState receive) split({bool useExtractedNonce = true}) {
    final output = _hkdf(_chainingKey, Uint8List(0), 2);
    final sodium = sodiumInstance;
    final c1 = NoiseCipherState(useExtractedNonce: useExtractedNonce);
    c1.initializeKey(SecureKey.fromList(sodium, output[0]));
    final c2 = NoiseCipherState(useExtractedNonce: useExtractedNonce);
    c2.initializeKey(SecureKey.fromList(sodium, output[1]));

    // Clear sensitive state after split
    _chainingKey.fillRange(0, _chainingKey.length, 0);
    _hash.fillRange(0, _hash.length, 0);
    _cipherState.clear();

    return (c1, c2);
  }

  // HKDF using HMAC-SHA256
  List<Uint8List> _hkdf(Uint8List chainingKey, Uint8List inputKeyMaterial, int numOutputs) {
    final sodium = sodiumInstance;
    final tempKey = sodium.crypto.auth(
      message: inputKeyMaterial,
      key: SecureKey.fromList(sodium, chainingKey),
    );

    final outputs = <Uint8List>[];
    var currentOutput = Uint8List(0);

    for (var i = 1; i <= numOutputs; i++) {
      final input = Uint8List(currentOutput.length + 1);
      input.setAll(0, currentOutput);
      input[input.length - 1] = i;
      currentOutput = sodium.crypto.auth(
        message: input,
        key: SecureKey.fromList(sodium, tempKey),
      );
      outputs.add(currentOutput);
    }

    return outputs;
  }

  Uint8List _sha256(Uint8List data) {
    final sodium = sodiumInstance;
    return sodium.crypto.genericHash(message: data, outLen: 32);
  }
}

/// HandshakeState — orchestrates the complete Noise XX handshake.
///
/// Ported from Bitchat's NoiseHandshakeState.
///
/// XX handshake flow:
/// ```
/// Initiator              Responder
/// -> e                   (ephemeral key)
/// <- e, ee, s, es        (ephemeral, DH, static encrypted, DH)
/// -> s, se               (static encrypted, DH)
/// ```
class NoiseHandshakeState {
  final NoiseRole role;
  final NoisePattern pattern;
  final NoiseSymmetricState _symmetricState;
  final List<List<NoiseMessageToken>> _messagePatterns;
  int _currentPattern = 0;

  // Key pairs (using raw 32-byte keys for X25519)
  Uint8List? localStaticPrivate;
  Uint8List? localStaticPublic;
  Uint8List? localEphemeralPrivate;
  Uint8List? localEphemeralPublic;
  Uint8List? remoteStaticPublic;
  Uint8List? remoteEphemeralPublic;

  NoiseHandshakeState({
    required this.role,
    this.pattern = NoisePattern.xx,
    Uint8List? localStaticPrivateKey,
    Uint8List? localStaticPublicKey,
    Uint8List? remoteStaticKey,
    Uint8List? prologue,
  })  : _symmetricState = NoiseSymmetricState(pattern.protocolName),
        _messagePatterns = pattern.messagePatterns {
    localStaticPrivate = localStaticPrivateKey;
    localStaticPublic = localStaticPublicKey;
    remoteStaticPublic = remoteStaticKey;

    // Mix prologue
    _symmetricState.mixHash(prologue ?? Uint8List(0));
  }

  bool get isComplete => _currentPattern >= _messagePatterns.length;

  Uint8List get handshakeHash => _symmetricState.handshakeHash;

  /// Write the next handshake message.
  Uint8List writeMessage({Uint8List? payload}) {
    if (isComplete) throw const NoiseException(NoiseError.handshakeComplete);

    final buffer = <int>[];
    final tokens = _messagePatterns[_currentPattern];

    for (final token in tokens) {
      switch (token) {
        case NoiseMessageToken.e:
          _generateEphemeralKey();
          buffer.addAll(localEphemeralPublic!);
          _symmetricState.mixHash(localEphemeralPublic!);
        case NoiseMessageToken.s:
          if (localStaticPublic == null) {
            throw const NoiseException(NoiseError.missingLocalStaticKey);
          }
          final encrypted = _symmetricState.encryptAndHash(localStaticPublic!);
          buffer.addAll(encrypted);
        case NoiseMessageToken.ee:
          _performDH(localEphemeralPrivate!, remoteEphemeralPublic!);
        case NoiseMessageToken.es:
          if (role == NoiseRole.initiator) {
            _performDH(localEphemeralPrivate!, remoteStaticPublic!);
          } else {
            _performDH(localStaticPrivate!, remoteEphemeralPublic!);
          }
        case NoiseMessageToken.se:
          if (role == NoiseRole.initiator) {
            _performDH(localStaticPrivate!, remoteEphemeralPublic!);
          } else {
            _performDH(localEphemeralPrivate!, remoteStaticPublic!);
          }
        case NoiseMessageToken.ss:
          _performDH(localStaticPrivate!, remoteStaticPublic!);
      }
    }

    final encryptedPayload = _symmetricState.encryptAndHash(payload ?? Uint8List(0));
    buffer.addAll(encryptedPayload);

    _currentPattern++;
    return Uint8List.fromList(buffer);
  }

  /// Read the next handshake message from the remote peer.
  Uint8List readMessage(Uint8List message) {
    if (isComplete) throw const NoiseException(NoiseError.handshakeComplete);

    var offset = 0;
    final tokens = _messagePatterns[_currentPattern];

    for (final token in tokens) {
      switch (token) {
        case NoiseMessageToken.e:
          if (message.length - offset < 32) {
            throw const NoiseException(NoiseError.invalidMessage);
          }
          remoteEphemeralPublic = Uint8List.sublistView(message, offset, offset + 32);
          offset += 32;
          _symmetricState.mixHash(remoteEphemeralPublic!);
        case NoiseMessageToken.s:
          final keyLen = _symmetricState.hasCipherKey ? 48 : 32;
          if (message.length - offset < keyLen) {
            throw const NoiseException(NoiseError.invalidMessage);
          }
          final staticData = Uint8List.sublistView(message, offset, offset + keyLen);
          offset += keyLen;
          final decrypted = _symmetricState.decryptAndHash(staticData);
          remoteStaticPublic = decrypted;
        case NoiseMessageToken.ee:
          _performDH(localEphemeralPrivate!, remoteEphemeralPublic!);
        case NoiseMessageToken.es:
          if (role == NoiseRole.initiator) {
            _performDH(localEphemeralPrivate!, remoteStaticPublic!);
          } else {
            _performDH(localStaticPrivate!, remoteEphemeralPublic!);
          }
        case NoiseMessageToken.se:
          if (role == NoiseRole.initiator) {
            _performDH(localStaticPrivate!, remoteEphemeralPublic!);
          } else {
            _performDH(localEphemeralPrivate!, remoteStaticPublic!);
          }
        case NoiseMessageToken.ss:
          _performDH(localStaticPrivate!, remoteStaticPublic!);
      }
    }

    final remainingPayload = Uint8List.sublistView(message, offset);
    final payload = _symmetricState.decryptAndHash(remainingPayload);

    _currentPattern++;
    return payload;
  }

  /// Get transport cipher states after handshake is complete.
  ({NoiseCipherState send, NoiseCipherState receive, Uint8List handshakeHash}) getTransportCiphers({
    bool useExtractedNonce = true,
  }) {
    if (!isComplete) throw const NoiseException(NoiseError.handshakeNotComplete);

    final hash = _symmetricState.handshakeHash;
    final (c1, c2) = _symmetricState.split(useExtractedNonce: useExtractedNonce);

    // Initiator uses c1 for send, c2 for receive
    final ciphers = role == NoiseRole.initiator ? (c1, c2) : (c2, c1);
    return (send: ciphers.$1, receive: ciphers.$2, handshakeHash: hash);
  }

  void _generateEphemeralKey() {
    final sodium = sodiumInstance;
    final keyPair = sodium.crypto.box.keyPair();
    localEphemeralPrivate = keyPair.secretKey.extractBytes();
    localEphemeralPublic = Uint8List.fromList(keyPair.publicKey);
  }

  void _performDH(Uint8List privateKey, Uint8List publicKey) {
    final sodium = sodiumInstance;
    final sharedSecret = sodium.crypto.scalarmult(
      n: SecureKey.fromList(sodium, privateKey),
      p: publicKey,
    );
    _symmetricState.mixKey(sharedSecret.extractBytes());
  }
}
