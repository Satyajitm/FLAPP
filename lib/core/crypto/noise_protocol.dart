import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as pkg_crypto;
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

  /// Reusable 8-byte nonce buffer — avoids allocating a new Uint8List on
  /// every encrypt/decrypt call (safe because Dart is single-threaded and
  /// libsodium copies the nonce before returning).
  /// NOTE: sodium-2.x only exposes aeadChaCha20Poly1305 (8-byte non-IETF nonce)
  /// at the Dart API level. The aeadChaCha20Poly1305IETF (12-byte) C function
  /// is not separately wrapped. We continue to use the 8-byte variant.
  final Uint8List _nonceBuffer = Uint8List(8);
  late final ByteData _nonceBufferData = ByteData.sublistView(_nonceBuffer);

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
    // HIGH-3: Use >= to catch the nonce exactly at 0xFFFFFFFF before overflow.
    if (_nonce >= 0xFFFFFFFF) throw const NoiseException(NoiseError.nonceExceeded);

    final currentNonce = _nonce;

    // Build 8-byte nonce: big-endian counter for aeadChaCha20Poly1305.
    _nonceBufferData.setUint64(0, currentNonce, Endian.big);

    final sodium = sodiumInstance;
    final ciphertext = sodium.crypto.aeadChaCha20Poly1305.encrypt(
      message: plaintext,
      nonce: _nonceBuffer,
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

    // Build 8-byte nonce: big-endian counter for aeadChaCha20Poly1305.
    _nonceBufferData.setUint64(0, decryptionNonce, Endian.big);

    final sodium = sodiumInstance;
    try {
      final plaintext = sodium.crypto.aeadChaCha20Poly1305.decrypt(
        cipherText: actualCiphertext,
        nonce: _nonceBuffer,
        key: _key!,
        additionalData: ad,
      );

      if (useExtractedNonce) {
        _markNonceAsSeen(decryptionNonce);
        // HIGH-3: Don't increment the internal counter when using extracted
        // nonces — the counter is only used for non-extracted-nonce sessions
        // (i.e., handshake phase). During transport, the received nonce IS
        // the authoritative value tracked by the replay window.
      } else {
        _nonce++;
      }

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

  // HIGH-4: Fixed sliding window shift. The bitmap encodes:
  //   _replayWindow[byteIdx] bit `bitIdx` = nonce at offset `byteIdx*8 + bitIdx`
  //   from _highestReceivedNonce (offset 0 = most recent).
  // When the highest nonce advances by `shift`, all existing offsets increase
  // by `shift`, so old data must move toward HIGHER byte/bit indices.
  void _markNonceAsSeen(int receivedNonce) {
    if (receivedNonce > _highestReceivedNonce) {
      final shift = receivedNonce - _highestReceivedNonce;
      if (shift >= replayWindowSize) {
        _replayWindow.fillRange(0, replayWindowBytes, 0);
      } else {
        final byteShift = shift ~/ 8;
        final bitShift = shift % 8;
        // Iterate from high to low so reads always come from unmodified source.
        for (var j = replayWindowBytes - 1; j >= 0; j--) {
          final hiSrc = j - byteShift;
          final loSrc = j - byteShift - 1;
          int newByte = 0;
          if (hiSrc >= 0) {
            // Upper bits of new byte j come from lower bits of old byte hiSrc.
            newByte = (_replayWindow[hiSrc] << bitShift) & 0xFF;
          }
          if (loSrc >= 0 && bitShift > 0) {
            // Lower bits of new byte j carry over from upper bits of old byte loSrc.
            newByte |= _replayWindow[loSrc] >> (8 - bitShift);
          }
          _replayWindow[j] = newByte;
        }
      }
      _highestReceivedNonce = receivedNonce;
      _replayWindow[0] |= 1; // Mark new highest nonce (offset 0) as seen.
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

  /// MED-N4: Zero handshake chaining key and hash on failure paths.
  ///
  /// Called from [NoiseHandshakeState.dispose] to clear intermediate key
  /// material that is not zeroed by the normal [split] success path.
  void dispose() {
    _chainingKey.fillRange(0, _chainingKey.length, 0);
    _hash.fillRange(0, _hash.length, 0);
    _cipherState.clear();
  }

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

  // HKDF-SHA256 per RFC 5869 / Noise Protocol spec.
  // Uses HMAC-SHA256 (not crypto_auth which is HMAC-SHA512/256).
  List<Uint8List> _hkdf(Uint8List chainingKey, Uint8List inputKeyMaterial, int numOutputs) {
    // HKDF-Extract: tempKey = HMAC-SHA256(chainingKey, inputKeyMaterial)
    final tempKey = _hmacSha256(chainingKey, inputKeyMaterial);

    // HKDF-Expand: T(1) = HMAC-SHA256(tempKey, 0x01), T(2) = HMAC-SHA256(tempKey, T(1) || 0x02), …
    final outputs = <Uint8List>[];
    var currentOutput = Uint8List(0);

    for (var i = 1; i <= numOutputs; i++) {
      final input = Uint8List(currentOutput.length + 1);
      input.setAll(0, currentOutput);
      input[input.length - 1] = i;
      currentOutput = _hmacSha256(tempKey, input);
      outputs.add(currentOutput);
    }

    return outputs;
  }

  /// HMAC-SHA256: keyed hash using the dart:crypto sha256 primitive.
  ///
  /// This produces a correct 32-byte HMAC-SHA256 output as required by
  /// the Noise Protocol Framework spec (https://noiseprotocol.org/noise.html).
  Uint8List _hmacSha256(Uint8List key, Uint8List message) {
    final hmac = pkg_crypto.Hmac(pkg_crypto.sha256, key);
    final digest = hmac.convert(message);
    return Uint8List.fromList(digest.bytes);
  }

  /// LOW-C1: Use actual SHA-256 (not BLAKE2b) as required by the Noise spec.
  /// pkg_crypto.sha256 is already imported for HMAC-SHA256.
  Uint8List _sha256(Uint8List data) {
    final digest = pkg_crypto.sha256.convert(data);
    return Uint8List.fromList(digest.bytes);
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
          // C3: Validate that the decrypted static public key is exactly 32 bytes.
          if (decrypted.length != 32) {
            throw const NoiseException(NoiseError.invalidPublicKey);
          }
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
    keyPair.secretKey.dispose(); // Zero SecureKey after extracting bytes
  }

  void _performDH(Uint8List privateKey, Uint8List publicKey) {
    final sodium = sodiumInstance;
    // H4: Wrap the private key in a SecureKey and dispose it in finally to
    // ensure the libsodium-guarded buffer is zeroed even on exception paths.
    final skWrapper = SecureKey.fromList(sodium, privateKey);
    try {
      final sharedSecret = sodium.crypto.scalarmult(
        n: skWrapper,
        p: publicKey,
      );
      final sharedBytes = sharedSecret.extractBytes();
      _symmetricState.mixKey(sharedBytes);
      // Zero shared secret bytes immediately after use
      for (int i = 0; i < sharedBytes.length; i++) sharedBytes[i] = 0;
    } finally {
      skWrapper.dispose();
    }
  }

  /// Zero all sensitive key material held in this handshake state.
  ///
  /// Call after [getTransportCiphers] or when aborting the handshake.
  void dispose() {
    if (localStaticPrivate != null) {
      for (int i = 0; i < localStaticPrivate!.length; i++) localStaticPrivate![i] = 0;
      localStaticPrivate = null;
    }
    if (localEphemeralPrivate != null) {
      for (int i = 0; i < localEphemeralPrivate!.length; i++) localEphemeralPrivate![i] = 0;
      localEphemeralPrivate = null;
    }
    if (localEphemeralPublic != null) {
      for (int i = 0; i < localEphemeralPublic!.length; i++) localEphemeralPublic![i] = 0;
      localEphemeralPublic = null;
    }
    if (remoteStaticPublic != null) {
      for (int i = 0; i < remoteStaticPublic!.length; i++) remoteStaticPublic![i] = 0;
      remoteStaticPublic = null;
    }
    if (remoteEphemeralPublic != null) {
      for (int i = 0; i < remoteEphemeralPublic!.length; i++) remoteEphemeralPublic![i] = 0;
      remoteEphemeralPublic = null;
    }
    // MED-N4: Dispose symmetric state to zero _chainingKey and _hash on all
    // failure paths (not just the split() success path).
    _symmetricState.dispose();
  }
}
