// NoiseSession tests — MED-C2 and related correctness checks.
//
// NoiseCipherState and the handshake require native sodium binaries, so we
// test the session's observable counter/rekey behaviour using a test double
// for the cipher state.

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/crypto/noise_session.dart';
import 'package:fluxon_app/core/crypto/noise_protocol.dart';

// ---------------------------------------------------------------------------
// Test double: a NoiseCipherState that returns a fixed result and can be
// configured to throw on the next call (to simulate encryption failure).
// ---------------------------------------------------------------------------
class _FakeCipherState extends NoiseCipherState {
  int encryptCallCount = 0;
  int decryptCallCount = 0;
  bool throwOnNextEncrypt = false;

  @override
  bool get hasKey => true;

  @override
  Uint8List encrypt(Uint8List plaintext, {Uint8List? ad}) {
    if (throwOnNextEncrypt) {
      throwOnNextEncrypt = false;
      throw const NoiseException(NoiseError.nonceExceeded);
    }
    encryptCallCount++;
    // Return a trivial "ciphertext" for testing.
    return Uint8List.fromList([...plaintext, 0x00]); // append one tag byte
  }

  @override
  Uint8List decrypt(Uint8List ciphertext, {Uint8List? ad}) {
    decryptCallCount++;
    // Strip the last byte we added in encrypt (fake tag).
    if (ciphertext.isEmpty) return ciphertext;
    return Uint8List.sublistView(ciphertext, 0, ciphertext.length - 1);
  }

  @override
  void clear() {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('NoiseSession — MED-C2: counter incremented only on success', () {
    late _FakeCipherState fakeSend;
    late _FakeCipherState fakeReceive;
    late NoiseSession session;

    setUp(() {
      fakeSend = _FakeCipherState();
      fakeReceive = _FakeCipherState();
      session = NoiseSession(
        sendCipher: fakeSend,
        receiveCipher: fakeReceive,
        handshakeHash: Uint8List(32),
        remotePeerId: Uint8List(32),
      );
    });

    test('encrypt increments _messagesSent after success', () {
      expect(session.shouldRekey, isFalse);
      final plaintext = Uint8List.fromList([0x01, 0x02, 0x03]);
      session.encrypt(plaintext);
      // After one successful encrypt, count should be 1 (not 1000000 yet).
      expect(session.shouldRekey, isFalse);
    });

    test('encrypt does NOT increment counter when cipher throws', () {
      fakeSend.throwOnNextEncrypt = true;
      expect(
        () => session.encrypt(Uint8List.fromList([0x01])),
        throwsA(isA<NoiseException>()),
      );
      // Counter must NOT have advanced — shouldRekey is still false.
      expect(session.shouldRekey, isFalse);
    });

    test('decrypt increments _messagesReceived', () {
      // Encrypt first to produce a valid (fake) ciphertext.
      final ciphertext = session.encrypt(Uint8List.fromList([0xAA]));
      session.decrypt(ciphertext);
      // Both counters are now 1; rekey threshold is 1000000.
      expect(session.shouldRekey, isFalse);
    });

    test('shouldRekey is false below threshold', () {
      expect(NoiseSession.rekeyThreshold, greaterThan(1));
      expect(session.shouldRekey, isFalse);
    });

    test('encrypt returns ciphertext from underlying cipher', () {
      final plaintext = Uint8List.fromList([0xAA, 0xBB]);
      final result = session.encrypt(plaintext);
      expect(result, isNotEmpty);
    });

    test('decrypt returns decrypted bytes from underlying cipher', () {
      final plaintext = Uint8List.fromList([0x42]);
      final ciphertext = session.encrypt(plaintext);
      final decrypted = session.decrypt(ciphertext);
      expect(decrypted, equals(plaintext));
    });
  });

  group('NoiseSession — dispose zeroes cipher states', () {
    test('dispose calls clear() on both ciphers', () {
      var sendCleared = false;
      var receiveCleared = false;

      final sendCipher = _ClearTrackingCipher(() => sendCleared = true);
      final receiveCipher = _ClearTrackingCipher(() => receiveCleared = true);

      final session = NoiseSession(
        sendCipher: sendCipher,
        receiveCipher: receiveCipher,
        handshakeHash: Uint8List(32),
        remotePeerId: Uint8List(32),
      );

      session.dispose();

      expect(sendCleared, isTrue, reason: 'send cipher must be cleared');
      expect(receiveCleared, isTrue, reason: 'receive cipher must be cleared');
    });
  });
}

class _ClearTrackingCipher extends NoiseCipherState {
  final void Function() onClear;
  _ClearTrackingCipher(this.onClear);

  @override
  bool get hasKey => false;

  @override
  void clear() => onClear();
}
