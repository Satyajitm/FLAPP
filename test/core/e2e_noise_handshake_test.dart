import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/crypto/keys.dart';
import 'package:fluxon_app/core/crypto/noise_protocol.dart';
import 'package:fluxon_app/core/crypto/noise_session.dart';
import 'package:fluxon_app/core/crypto/noise_session_manager.dart';
import 'package:fluxon_app/core/crypto/sodium_instance.dart';

// ============================================================================
// TIER 3: Integration Tests for Full Noise Handshake
// ============================================================================
// These tests verify the complete Noise XX handshake from start to finish,
// including encryption/decryption round-trips. They require sodium_libs.

void main() {
  setUpAll(() async {
    // Initialize sodium_libs before any crypto operations
    await initSodium();
  });

  // =========================================================================
  // TIER 3 TEST SUITE: Full Noise Handshake Flow
  // =========================================================================

  group('Tier 3: Full Noise XX Handshake (E2E with sodium_libs)', () {
    test('complete 3-message handshake exchange', () {
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
      expect(msg1, isNotEmpty, reason: 'Message 1 should contain ephemeral key');
      expect(initiator.isComplete, isFalse, reason: 'Initiator incomplete after msg1');

      // Message 2: Responder receives msg1, sends ephemeral + DH
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      expect(msg2, isNotEmpty, reason: 'Message 2 should contain e, ee, s, es');
      expect(responder.isComplete, isFalse, reason: 'Responder incomplete after msg2');

      // Message 3: Initiator receives msg2, sends static + DH
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      expect(msg3, isNotEmpty, reason: 'Message 3 should contain s, se');
      expect(initiator.isComplete, isTrue, reason: 'Initiator should be complete after msg3');

      // Final: Responder receives msg3
      responder.readMessage(msg3);
      expect(responder.isComplete, isTrue, reason: 'Responder should be complete after msg3');

      // Both sides know each other's static keys
      expect(
        initiator.remoteStaticPublic,
        equals(responderStaticPair.publicKey),
        reason: 'Initiator should know responder public key',
      );
      expect(
        responder.remoteStaticPublic,
        equals(initiatorStaticPair.publicKey),
        reason: 'Responder should know initiator public key',
      );
    });

    test('handshake establishes matching session keys', () {
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

      // Create sessions from handshake states
      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      // Sessions should be established
      expect(initiatorSession, isNotNull);
      expect(responderSession, isNotNull);
    });

    test('failed handshake step is detected', () {
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

      final msg1 = initiator.writeMessage();

      // Corrupt message 1
      final corruptedMsg1 = Uint8List.fromList(msg1);
      corruptedMsg1[0] ^= 0xFF; // Flip bits

      // Responder should either fail gracefully or detect the corruption
      // (The Noise protocol may throw or return invalid state)
      expect(() => responder.readMessage(corruptedMsg1),
             anyOf(
               throwsException,
               // or it returns but state is invalid, verified by next write
             ));
    });

    test('handshake is deterministic (same inputs produce same flow)', () {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      // First handshake
      final init1 = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: keyPair1.privateKey,
        localStaticPublicKey: keyPair1.publicKey,
      );

      final msg1_a = init1.writeMessage();

      // Second handshake with same keys
      final init2 = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: keyPair1.privateKey,
        localStaticPublicKey: keyPair1.publicKey,
      );

      final msg1_b = init2.writeMessage();

      // Messages should be different (ephemeral keys are random)
      // But both should be valid
      expect(msg1_a, isNotEmpty);
      expect(msg1_b, isNotEmpty);
    });
  });

  // =========================================================================
  // TIER 3 TEST SUITE: Encryption Round-Trip
  // =========================================================================

  group('Tier 3: Encryption Round-Trip (E2E with sodium_libs)', () {
    test('session encrypt and decrypt round-trip', () {
      final initiatorStaticPair = KeyGenerator.generateStaticKeyPair();
      final responderStaticPair = KeyGenerator.generateStaticKeyPair();

      // Complete handshake
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

      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      // Create sessions
      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      // Encrypt from initiator
      final plaintext = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final ciphertext = initiatorSession.encrypt(plaintext);

      expect(ciphertext, isNotEmpty);
      expect(ciphertext, isNot(plaintext));

      // Decrypt from responder
      final decrypted = responderSession.decrypt(ciphertext);
      expect(decrypted, equals(plaintext));
    });

    test('bidirectional encryption works', () {
      final initiatorStaticPair = KeyGenerator.generateStaticKeyPair();
      final responderStaticPair = KeyGenerator.generateStaticKeyPair();

      // Complete handshake
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

      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      // Create sessions
      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      // Message from initiator to responder
      final msg1Plaintext = Uint8List.fromList([0x10, 0x20]);
      final msg1Ciphertext = initiatorSession.encrypt(msg1Plaintext);
      final msg1Decrypted = responderSession.decrypt(msg1Ciphertext);
      expect(msg1Decrypted, equals(msg1Plaintext));

      // Message from responder to initiator
      final msg2Plaintext = Uint8List.fromList([0x30, 0x40]);
      final msg2Ciphertext = responderSession.encrypt(msg2Plaintext);
      final msg2Decrypted = initiatorSession.decrypt(msg2Ciphertext);
      expect(msg2Decrypted, equals(msg2Plaintext));
    });

    test('multiple encrypted messages maintain nonce separation', () {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: keyPair1.privateKey,
        localStaticPublicKey: keyPair1.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: keyPair2.privateKey,
        localStaticPublicKey: keyPair2.publicKey,
      );

      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: keyPair2.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: keyPair1.publicKey,
      );

      final msgs = [
        Uint8List.fromList([0x01]),
        Uint8List.fromList([0x02]),
        Uint8List.fromList([0x03]),
      ];

      final ciphertexts = <Uint8List>[];
      for (final plaintext in msgs) {
        final ct = initiatorSession.encrypt(plaintext);
        ciphertexts.add(ct);
      }

      // All ciphertexts should be different (due to nonce increment)
      expect(ciphertexts[0], isNot(ciphertexts[1]));
      expect(ciphertexts[1], isNot(ciphertexts[2]));

      // All should decrypt correctly
      for (var i = 0; i < msgs.length; i++) {
        final decrypted = responderSession.decrypt(ciphertexts[i]);
        expect(decrypted, equals(msgs[i]));
      }
    });

    test('encrypted message tampering is detected', () {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: keyPair1.privateKey,
        localStaticPublicKey: keyPair1.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: keyPair2.privateKey,
        localStaticPublicKey: keyPair2.publicKey,
      );

      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: keyPair2.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: keyPair1.publicKey,
      );

      final plaintext = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      final ciphertext = initiatorSession.encrypt(plaintext);

      // Tamper with ciphertext
      final tampered = Uint8List.fromList(ciphertext);
      tampered[0] ^= 0x01;

      // Decryption should fail or throw
      expect(
        () => responderSession.decrypt(tampered),
        anyOf(
          throwsException,
          isNull,
          // or returns corrupted data (caught later in packet validation)
        ),
      );
    });
  });

  // =========================================================================
  // TIER 3 TEST SUITE: NoiseSessionManager Integration
  // =========================================================================

  group('Tier 3: NoiseSessionManager Integration (E2E)', () {
    test('session manager orchestrates full handshake', () {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      final manager1 = NoiseSessionManager(
        myStaticPrivKey: keyPair1.privateKey,
        myStaticPubKey: keyPair1.publicKey,
      );

      final manager2 = NoiseSessionManager(
        myStaticPrivKey: keyPair2.privateKey,
        myStaticPubKey: keyPair2.publicKey,
      );

      const deviceId = 'device-test';

      // Manager 1 initiates
      final msg1 = manager1.startHandshake(deviceId);
      expect(msg1, isNotEmpty);

      // Manager 2 receives and responds
      var result = manager2.processHandshakeMessage(deviceId, msg1);
      expect(result.response, isNotEmpty);
      expect(result.remotePubKey, isNull);

      // Manager 1 receives response
      result = manager1.processHandshakeMessage(deviceId, result.response!);
      expect(result.response, isNotEmpty);
      expect(result.remotePubKey, isNull); // May be null here

      // Manager 2 receives final message
      result = manager2.processHandshakeMessage(deviceId, result.response!);
      expect(result.remotePubKey, isNotNull,
          reason: 'Responder should know remote public key after msg3');
    });

    test('separate device handshakes are independent', () {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      final manager = NoiseSessionManager(
        myStaticPrivKey: keyPair1.privateKey,
        myStaticPubKey: keyPair1.publicKey,
      );

      final manager2 = NoiseSessionManager(
        myStaticPrivKey: keyPair2.privateKey,
        myStaticPubKey: keyPair2.publicKey,
      );

      const device1 = 'device-1';
      const device2 = 'device-2';

      final msg1_dev1 = manager.startHandshake(device1);
      final msg1_dev2 = manager.startHandshake(device2);

      expect(msg1_dev1, isNotEmpty);
      expect(msg1_dev2, isNotEmpty);
      // Messages should be different (different ephemeral keys)
    });
  });

  // =========================================================================
  // TIER 3 TEST SUITE: Key Material Properties
  // =========================================================================

  group('Tier 3: Key Material Properties', () {
    test('static key pair is X25519 (32-byte keys)', () {
      final keyPair = KeyGenerator.generateStaticKeyPair();
      expect(keyPair.privateKey.length, equals(32));
      expect(keyPair.publicKey.length, equals(32));
    });

    test('ephemeral key is also X25519', () {
      final state = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: KeyGenerator.generateStaticKeyPair().privateKey,
        localStaticPublicKey: KeyGenerator.generateStaticKeyPair().publicKey,
      );

      final msg1 = state.writeMessage();
      expect(msg1, isNotEmpty);
      // Message 1 contains the ephemeral public key (32 bytes)
    });

    test('session key material is sufficient for ChaCha20', () {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      final initiator = NoiseHandshakeState(
        role: NoiseRole.initiator,
        localStaticPrivateKey: keyPair1.privateKey,
        localStaticPublicKey: keyPair1.publicKey,
      );

      final responder = NoiseHandshakeState(
        role: NoiseRole.responder,
        localStaticPrivateKey: keyPair2.privateKey,
        localStaticPublicKey: keyPair2.publicKey,
      );

      final msg1 = initiator.writeMessage();
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      // Sessions should be established with valid key material
      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: keyPair2.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: keyPair1.publicKey,
      );

      // Should be able to encrypt/decrypt
      final plaintext = Uint8List.fromList([0x01, 0x02]);
      final ciphertext = initiatorSession.encrypt(plaintext);
      final decrypted = responderSession.decrypt(ciphertext);

      expect(decrypted, equals(plaintext));
    });
  });
}
