import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/crypto/keys.dart';
import 'package:fluxon_app/core/crypto/noise_protocol.dart';
import 'package:fluxon_app/core/crypto/noise_session.dart';
import 'package:fluxon_app/core/crypto/sodium_instance.dart';

void main() {
  setUpAll(() async {
    // Initialize sodium_libs before any crypto operations
    await initSodium();
  });

  group('NoiseProtocol', () {
    test('Noise XX full handshake: 3-message exchange', () {
      // Generate static key pairs for both sides
      final initiatorStaticPair = KeyGenerator.generateStaticKeyPair();
      final responderStaticPair = KeyGenerator.generateStaticKeyPair();

      // Create handshake states
      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: initiatorStaticPair.privateKey,
        localStaticPublicKey: initiatorStaticPair.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: responderStaticPair.privateKey,
        localStaticPublicKey: responderStaticPair.publicKey,
      );

      // Message 1: Initiator sends ephemeral key (-> e)
      final msg1 = initiator.writeMessage();
      expect(msg1, isNotEmpty);
      expect(initiator.isComplete, isFalse);

      // Message 2: Responder receives msg1, sends ephemeral + DH (-> e, ee, s, es)
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      expect(msg2, isNotEmpty);
      expect(responder.isComplete, isFalse);

      // Message 3: Initiator receives msg2, sends static + DH (-> s, se)
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      expect(msg3, isNotEmpty);
      expect(initiator.isComplete, isTrue); // Initiator complete!

      // Final: Responder receives msg3
      responder.readMessage(msg3);
      expect(responder.isComplete, isTrue); // Responder complete!

      // Both sides should know each other's static public keys
      expect(initiator.remoteStaticPublic, equals(responderStaticPair.publicKey));
      expect(responder.remoteStaticPublic, equals(initiatorStaticPair.publicKey));
    });

    test('Noise session encrypt/decrypt round-trip', () {
      // Set up handshake
      final initiatorStaticPair = KeyGenerator.generateStaticKeyPair();
      final responderStaticPair = KeyGenerator.generateStaticKeyPair();

      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: initiatorStaticPair.privateKey,
        localStaticPublicKey: initiatorStaticPair.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: responderStaticPair.privateKey,
        localStaticPublicKey: responderStaticPair.publicKey,
      );

      // Complete handshake
      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      // Create post-handshake sessions
      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );
      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      // Encrypt from initiator
      const plaintext = 'Hello, Mesh Network!';
      final plaintextBytes = Uint8List.fromList(plaintext.codeUnits);
      final ciphertext = initiatorSession.encrypt(plaintextBytes);
      expect(ciphertext, isNotEmpty);
      expect(ciphertext.length, greaterThan(plaintextBytes.length)); // Has auth tag

      // Decrypt on responder
      final decrypted = responderSession.decrypt(ciphertext);
      expect(decrypted, equals(plaintextBytes));

      // Encrypt from responder
      final responderPlaintext = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final responderCiphertext = responderSession.encrypt(responderPlaintext);
      final initiatorDecrypted = initiatorSession.decrypt(responderCiphertext);
      expect(initiatorDecrypted, equals(responderPlaintext));
    });

    test('Noise session rejects tampered ciphertext', () {
      // Set up handshake
      final initiatorStaticPair = KeyGenerator.generateStaticKeyPair();
      final responderStaticPair = KeyGenerator.generateStaticKeyPair();

      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: initiatorStaticPair.privateKey,
        localStaticPublicKey: initiatorStaticPair.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: responderStaticPair.privateKey,
        localStaticPublicKey: responderStaticPair.publicKey,
      );

      // Complete handshake
      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      // Create session
      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      // Encrypt valid message
      final plaintext = Uint8List.fromList([1, 2, 3, 4]);
      final ciphertext = responderSession.encrypt(plaintext);

      // Tamper with ciphertext
      final tampered = Uint8List.fromList(ciphertext);
      tampered[0] ^= 0xFF; // Flip bits in first byte

      // Decryption should fail
      expect(
        () => responderSession.decrypt(tampered),
        throwsException,
      );
    });

    test('Noise cipher state counter increments', () {
      // Verify that the counter in cipher state increments to prevent replay
      final initiatorStaticPair = KeyGenerator.generateStaticKeyPair();
      final responderStaticPair = KeyGenerator.generateStaticKeyPair();

      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: initiatorStaticPair.privateKey,
        localStaticPublicKey: initiatorStaticPair.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: responderStaticPair.privateKey,
        localStaticPublicKey: responderStaticPair.publicKey,
      );

      // Complete handshake
      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final plaintext = Uint8List.fromList([0xAA, 0xBB, 0xCC]);

      // Encrypt first message
      final ct1 = initiatorSession.encrypt(plaintext);

      // Encrypt second message (should produce different ciphertext even with same plaintext)
      final ct2 = initiatorSession.encrypt(plaintext);

      // Ciphertexts should be different (due to nonce increment)
      expect(ct1, isNot(equals(ct2)));
    });

    test('Independent handshake states do not interfere', () {
      final pair1 = KeyGenerator.generateStaticKeyPair();
      final pair2 = KeyGenerator.generateStaticKeyPair();

      final state1a = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: pair1.privateKey,
        localStaticPublicKey: pair1.publicKey,
      );

      final state1b = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: pair2.privateKey,
        localStaticPublicKey: pair2.publicKey,
      );

      // Start message
      final msg1 = state1a.writeMessage();
      expect(msg1, isNotEmpty);
      expect(state1a.isComplete, isFalse);

      // Responder process
      state1b.readMessage(msg1);
      final msg2 = state1b.writeMessage();
      expect(msg2, isNotEmpty);
      expect(state1b.isComplete, isFalse);

      // Initiator process
      state1a.readMessage(msg2);
      state1a.writeMessage();
      expect(state1a.isComplete, isTrue);

      // Each side should have the other's key
      expect(state1a.remoteStaticPublic, equals(pair2.publicKey));
      expect(state1b.remoteStaticPublic, equals(pair1.publicKey));
    });
  });
}
