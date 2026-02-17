import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/crypto/keys.dart';
import 'package:fluxon_app/core/crypto/noise_session_manager.dart';
import 'package:fluxon_app/core/crypto/signatures.dart';
import 'package:fluxon_app/core/crypto/sodium_instance.dart';

void main() {
  setUpAll(() async {
    // Initialize sodium_libs before any crypto operations
    await initSodium();
  });

  group('NoiseSessionManager', () {
    late NoiseSessionManager initiatorManager;
    late NoiseSessionManager responderManager;
    late Uint8List initiatorPrivKey;
    late Uint8List initiatorPubKey;
    late Uint8List responderPrivKey;
    late Uint8List responderPubKey;
    late Uint8List initiatorSigningKey;
    late Uint8List responderSigningKey;

    setUp(() {
      // Generate key pairs for both sides
      final initiatorPair = KeyGenerator.generateStaticKeyPair();
      initiatorPrivKey = initiatorPair.privateKey;
      initiatorPubKey = initiatorPair.publicKey;

      final responderPair = KeyGenerator.generateStaticKeyPair();
      responderPrivKey = responderPair.privateKey;
      responderPubKey = responderPair.publicKey;

      // Generate signing keys for testing
      final initiatorSigningPair = Signatures.generateSigningKeyPair();
      initiatorSigningKey = initiatorSigningPair.publicKey;

      final responderSigningPair = Signatures.generateSigningKeyPair();
      responderSigningKey = responderSigningPair.publicKey;

      // Create managers
      initiatorManager = NoiseSessionManager(
        myStaticPrivKey: initiatorPrivKey,
        myStaticPubKey: initiatorPubKey,
        localSigningPublicKey: initiatorSigningKey,
      );

      responderManager = NoiseSessionManager(
        myStaticPrivKey: responderPrivKey,
        myStaticPubKey: responderPubKey,
        localSigningPublicKey: responderSigningKey,
      );
    });

    tearDown(() {
      initiatorManager.clear();
      responderManager.clear();
    });

    test('startHandshake returns valid message 1', () {
      final deviceId = 'test_device_1';
      final msg1 = initiatorManager.startHandshake(deviceId);

      // Message 1 should be non-empty Noise bytes (contains ephemeral key)
      expect(msg1, isNotEmpty);
      expect(msg1.length, greaterThan(0));
    });

    test('Full Noise XX handshake: initiator + responder', () {
      const deviceId = 'test_device_2';

      // Step 1: Initiator starts handshake (message 1: -> e)
      final msg1 = initiatorManager.startHandshake(deviceId);
      expect(msg1, isNotEmpty);

      // Step 2: Responder receives message 1
      final response1 = responderManager.processHandshakeMessage(deviceId, msg1);
      expect(response1.response, isNotNull); // Message 2
      expect(response1.remotePubKey, isNull); // Not complete yet
      final msg2 = response1.response!;

      // Step 3: Initiator receives message 2
      final response2 =
          initiatorManager.processHandshakeMessage(deviceId, msg2);
      expect(response2.response, isNotNull); // Message 3
      expect(response2.remotePubKey, isNotNull); // Handshake complete!
      final msg3 = response2.response!;
      final initiatorRemotePubKey = response2.remotePubKey!;

      // Step 4: Responder receives message 3
      final response3 =
          responderManager.processHandshakeMessage(deviceId, msg3);
      expect(response3.response, isNull); // No response needed
      expect(response3.remotePubKey, isNotNull); // Handshake complete!
      final responderRemotePubKey = response3.remotePubKey!;

      // Both sides should have learned the other's public key
      expect(initiatorRemotePubKey, equals(responderPubKey));
      expect(responderRemotePubKey, equals(initiatorPubKey));

      // Both sides should now have established sessions
      expect(initiatorManager.hasSession(deviceId), isTrue);
      expect(responderManager.hasSession(deviceId), isTrue);
    });

    test('encrypt/decrypt round-trip after handshake', () {
      const deviceId = 'test_device_3';
      const plaintext = 'Hello, Mesh!';
      final plaintextBytes = Uint8List.fromList(plaintext.codeUnits);

      // Complete the handshake
      final msg1 = initiatorManager.startHandshake(deviceId);
      final msg2 =
          responderManager.processHandshakeMessage(deviceId, msg1).response!;
      final msg3 =
          initiatorManager.processHandshakeMessage(deviceId, msg2).response!;
      responderManager.processHandshakeMessage(deviceId, msg3);

      // Initiator encrypts and responder decrypts
      final ciphertext =
          initiatorManager.encrypt(plaintextBytes, deviceId);
      expect(ciphertext, isNotNull);

      final decrypted =
          responderManager.decrypt(ciphertext!, deviceId);
      expect(decrypted, isNotNull);
      expect(decrypted, equals(plaintextBytes));
    });

    test('encrypt returns null if no session exists', () {
      const deviceId = 'nonexistent_device';
      final data = Uint8List.fromList([1, 2, 3]);

      final result = initiatorManager.encrypt(data, deviceId);
      expect(result, isNull);
    });

    test('decrypt returns null if no session exists', () {
      const deviceId = 'nonexistent_device';
      final data = Uint8List.fromList([1, 2, 3]);

      final result = initiatorManager.decrypt(data, deviceId);
      expect(result, isNull);
    });

    test('decrypt returns null on invalid ciphertext', () {
      const deviceId = 'test_device_4';

      // Complete handshake
      final msg1 = initiatorManager.startHandshake(deviceId);
      final msg2 =
          responderManager.processHandshakeMessage(deviceId, msg1).response!;
      final msg3 =
          initiatorManager.processHandshakeMessage(deviceId, msg2).response!;
      responderManager.processHandshakeMessage(deviceId, msg3);

      // Try to decrypt garbage data
      final garbage = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      final result = responderManager.decrypt(garbage, deviceId);
      expect(result, isNull);
    });

    test('removeSession cleans up handshake state', () {
      const deviceId = 'test_device_5';

      // Start handshake
      final msg1 = initiatorManager.startHandshake(deviceId);
      expect(initiatorManager.hasSession(deviceId), isFalse);

      // Process response and complete
      final msg2 =
          responderManager.processHandshakeMessage(deviceId, msg1).response!;
      initiatorManager.processHandshakeMessage(deviceId, msg2);
      expect(initiatorManager.hasSession(deviceId), isTrue);

      // Remove session
      initiatorManager.removeSession(deviceId);
      expect(initiatorManager.hasSession(deviceId), isFalse);
    });

    test('getRemotePubKey returns null before handshake complete', () {
      const deviceId = 'test_device_6';

      // Start handshake but don't complete it
      initiatorManager.startHandshake(deviceId);
      final result = initiatorManager.getRemotePubKey(deviceId);
      expect(result, isNull);
    });

    test('clear removes all sessions and pending handshakes', () {
      const device1 = 'device_1';
      const device2 = 'device_2';

      // Start handshakes with two devices
      initiatorManager.startHandshake(device1);
      initiatorManager.startHandshake(device2);

      expect(initiatorManager.hasSession(device1), isFalse);
      expect(initiatorManager.hasSession(device2), isFalse);

      // Clear all
      initiatorManager.clear();

      // Both should be gone
      expect(initiatorManager.hasSession(device1), isFalse);
      expect(initiatorManager.hasSession(device2), isFalse);
    });

    test('Multiple peers with independent sessions', () {
      const device1 = 'device_1';
      const device2 = 'device_2';

      // Complete handshake with device 1
      final msg1a = initiatorManager.startHandshake(device1);
      final msg2a =
          responderManager.processHandshakeMessage(device1, msg1a).response!;
      initiatorManager.processHandshakeMessage(device1, msg2a);

      // Complete independent handshake with device 2
      final msg1b = initiatorManager.startHandshake(device2);
      final msg2b =
          responderManager.processHandshakeMessage(device2, msg1b).response!;
      initiatorManager.processHandshakeMessage(device2, msg2b);

      // Both sessions should exist independently
      expect(initiatorManager.hasSession(device1), isTrue);
      expect(initiatorManager.hasSession(device2), isTrue);

      // Encrypt/decrypt with each independently
      final plaintext1 = Uint8List.fromList([1, 2, 3]);
      final plaintext2 = Uint8List.fromList([4, 5, 6]);

      final cipher1 = initiatorManager.encrypt(plaintext1, device1);
      final cipher2 = initiatorManager.encrypt(plaintext2, device2);

      // Each should decrypt with the correct device's session
      final decrypt1 = responderManager.decrypt(cipher1!, device1);
      final decrypt2 = responderManager.decrypt(cipher2!, device2);

      expect(decrypt1, equals(plaintext1));
      expect(decrypt2, equals(plaintext2));
    });
  });
}
