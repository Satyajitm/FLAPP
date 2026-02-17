// Integration test that runs all sodium-dependent tests on a real device.
// This ensures platform plugins (sodium_libs) are properly initialized.
//
// Run with: flutter test integration_test/crypto_on_device_test.dart -d <device-id>

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fluxon_app/core/crypto/keys.dart';
import 'package:fluxon_app/core/crypto/noise_protocol.dart';
import 'package:fluxon_app/core/crypto/noise_session.dart';
import 'package:fluxon_app/core/crypto/noise_session_manager.dart';
import 'package:fluxon_app/core/crypto/signatures.dart';
import 'package:fluxon_app/core/crypto/sodium_instance.dart';
import 'package:fluxon_app/core/identity/identity_manager.dart';
import 'package:fluxon_app/core/mesh/mesh_service.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/core/transport/transport.dart';

// ============================================================================
// Mocks
// ============================================================================

class MockIdentityManager extends Mock implements IdentityManager {
  final Uint8List _signingPrivateKey = Uint8List.fromList(
    List.generate(64, (i) => i & 0xFF),
  );
  final Uint8List _signingPublicKey = Uint8List.fromList(
    List.generate(32, (i) => (i + 100) & 0xFF),
  );
  final Uint8List _privateKey = Uint8List.fromList(
    List.generate(32, (i) => i & 0xFF),
  );
  final Uint8List _publicKey = Uint8List.fromList(
    List.generate(32, (i) => (i + 50) & 0xFF),
  );

  @override
  Uint8List get signingPrivateKey => _signingPrivateKey;

  @override
  Uint8List get signingPublicKey => _signingPublicKey;

  @override
  Uint8List get privateKey => _privateKey;

  @override
  Uint8List get publicKey => _publicKey;
}

class MockKeyManager extends Mock implements KeyManager {}

class MockIdentityManagerSimple extends Mock implements IdentityManager {
  final Uint8List _privKey = Uint8List.fromList(List.generate(32, (i) => i));
  final Uint8List _pubKey =
      Uint8List.fromList(List.generate(32, (i) => i + 100));

  @override
  Uint8List get privateKey => _privKey;

  @override
  Uint8List get publicKey => _pubKey;
}

// ============================================================================
// Helpers
// ============================================================================

Uint8List makePeerId(int fillByte) =>
    Uint8List(32)..fillRange(0, 32, fillByte);

FluxonPacket buildTestPacket({
  required MessageType type,
  required Uint8List sourceId,
  Uint8List? payload,
  int ttl = 5,
}) {
  return BinaryProtocol.buildPacket(
    type: type,
    sourceId: sourceId,
    payload: payload ?? Uint8List(0),
    ttl: ttl,
  );
}

// ============================================================================
// Main
// ============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initSodium();
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const Duration());
  });

  // ==========================================================================
  // 1. NoiseProtocol (from noise_test.dart) — 6 tests
  // ==========================================================================

  group('NoiseProtocol', () {
    testWidgets('Noise XX full handshake: 3-message exchange',
        (WidgetTester tester) async {
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
      expect(msg1, isNotEmpty);
      expect(initiator.isComplete, isFalse);

      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      expect(msg2, isNotEmpty);
      expect(responder.isComplete, isFalse);

      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      expect(msg3, isNotEmpty);
      expect(initiator.isComplete, isTrue);

      responder.readMessage(msg3);
      expect(responder.isComplete, isTrue);

      expect(
          initiator.remoteStaticPublic, equals(responderStaticPair.publicKey));
      expect(
          responder.remoteStaticPublic, equals(initiatorStaticPair.publicKey));
    });

    testWidgets('Noise session encrypt/decrypt round-trip',
        (WidgetTester tester) async {
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
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );
      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      const plaintext = 'Hello, Mesh Network!';
      final plaintextBytes = Uint8List.fromList(plaintext.codeUnits);
      final ciphertext = initiatorSession.encrypt(plaintextBytes);
      expect(ciphertext, isNotEmpty);
      expect(ciphertext.length, greaterThan(plaintextBytes.length));

      final decrypted = responderSession.decrypt(ciphertext);
      expect(decrypted, equals(plaintextBytes));

      final responderPlaintext = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final responderCiphertext = responderSession.encrypt(responderPlaintext);
      final initiatorDecrypted = initiatorSession.decrypt(responderCiphertext);
      expect(initiatorDecrypted, equals(responderPlaintext));
    });

    testWidgets('Noise session rejects tampered ciphertext',
        (WidgetTester tester) async {
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
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      final plaintext = Uint8List.fromList([1, 2, 3, 4]);
      final ciphertext = responderSession.encrypt(plaintext);

      final tampered = Uint8List.fromList(ciphertext);
      tampered[0] ^= 0xFF;

      expect(
        () => responderSession.decrypt(tampered),
        throwsException,
      );
    });

    testWidgets('Noise cipher state counter increments',
        (WidgetTester tester) async {
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
      final ct1 = initiatorSession.encrypt(plaintext);
      final ct2 = initiatorSession.encrypt(plaintext);

      expect(ct1, isNot(equals(ct2)));
    });

    testWidgets('Independent handshake states do not interfere',
        (WidgetTester tester) async {
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

      final msg1 = state1a.writeMessage();
      expect(msg1, isNotEmpty);

      state1b.readMessage(msg1);
      final msg2 = state1b.writeMessage();
      expect(msg2, isNotEmpty);

      state1a.readMessage(msg2);
      final msg3 = state1a.writeMessage();
      expect(state1a.isComplete, isTrue);

      state1b.readMessage(msg3);
      expect(state1b.isComplete, isTrue);

      expect(state1a.remoteStaticPublic, equals(pair2.publicKey));
      expect(state1b.remoteStaticPublic, equals(pair1.publicKey));
    });
  });

  // ==========================================================================
  // 2. NoiseSessionManager (from noise_session_manager_test.dart) — 12 tests
  // ==========================================================================

  group('NoiseSessionManager', () {
    late NoiseSessionManager initiatorManager;
    late NoiseSessionManager responderManager;
    late Uint8List initiatorPubKey;
    late Uint8List responderPubKey;

    setUp(() {
      final initiatorPair = KeyGenerator.generateStaticKeyPair();
      initiatorPubKey = initiatorPair.publicKey;

      final responderPair = KeyGenerator.generateStaticKeyPair();
      responderPubKey = responderPair.publicKey;

      final initiatorSigningPair = Signatures.generateSigningKeyPair();
      final responderSigningPair = Signatures.generateSigningKeyPair();

      initiatorManager = NoiseSessionManager(
        myStaticPrivKey: initiatorPair.privateKey,
        myStaticPubKey: initiatorPubKey,
        localSigningPublicKey: initiatorSigningPair.publicKey,
      );

      responderManager = NoiseSessionManager(
        myStaticPrivKey: responderPair.privateKey,
        myStaticPubKey: responderPubKey,
        localSigningPublicKey: responderSigningPair.publicKey,
      );
    });

    tearDown(() {
      initiatorManager.clear();
      responderManager.clear();
    });

    testWidgets('startHandshake returns valid message 1',
        (WidgetTester tester) async {
      final msg1 = initiatorManager.startHandshake('test_device_1');
      expect(msg1, isNotEmpty);
    });

    testWidgets('Full Noise XX handshake: initiator + responder',
        (WidgetTester tester) async {
      const deviceId = 'test_device_2';

      final msg1 = initiatorManager.startHandshake(deviceId);
      expect(msg1, isNotEmpty);

      final response1 =
          responderManager.processHandshakeMessage(deviceId, msg1);
      expect(response1.response, isNotNull);
      expect(response1.remotePubKey, isNull);
      final msg2 = response1.response!;

      final response2 =
          initiatorManager.processHandshakeMessage(deviceId, msg2);
      expect(response2.response, isNotNull);
      expect(response2.remotePubKey, isNotNull);
      final msg3 = response2.response!;
      final initiatorRemotePubKey = response2.remotePubKey!;

      final response3 =
          responderManager.processHandshakeMessage(deviceId, msg3);
      expect(response3.response, isNull);
      expect(response3.remotePubKey, isNotNull);
      final responderRemotePubKey = response3.remotePubKey!;

      expect(initiatorRemotePubKey, equals(responderPubKey));
      expect(responderRemotePubKey, equals(initiatorPubKey));

      expect(initiatorManager.hasSession(deviceId), isTrue);
      expect(responderManager.hasSession(deviceId), isTrue);
    });

    testWidgets('encrypt/decrypt round-trip after handshake',
        (WidgetTester tester) async {
      const deviceId = 'test_device_3';
      const plaintext = 'Hello, Mesh!';
      final plaintextBytes = Uint8List.fromList(plaintext.codeUnits);

      final msg1 = initiatorManager.startHandshake(deviceId);
      final msg2 = responderManager
          .processHandshakeMessage(deviceId, msg1)
          .response!;
      final msg3 = initiatorManager
          .processHandshakeMessage(deviceId, msg2)
          .response!;
      responderManager.processHandshakeMessage(deviceId, msg3);

      final ciphertext = initiatorManager.encrypt(plaintextBytes, deviceId);
      expect(ciphertext, isNotNull);

      final decrypted = responderManager.decrypt(ciphertext!, deviceId);
      expect(decrypted, isNotNull);
      expect(decrypted, equals(plaintextBytes));
    });

    testWidgets('encrypt returns null if no session exists',
        (WidgetTester tester) async {
      final data = Uint8List.fromList([1, 2, 3]);
      final result = initiatorManager.encrypt(data, 'nonexistent_device');
      expect(result, isNull);
    });

    testWidgets('decrypt returns null if no session exists',
        (WidgetTester tester) async {
      final data = Uint8List.fromList([1, 2, 3]);
      final result = initiatorManager.decrypt(data, 'nonexistent_device');
      expect(result, isNull);
    });

    testWidgets('decrypt returns null on invalid ciphertext',
        (WidgetTester tester) async {
      const deviceId = 'test_device_4';

      final msg1 = initiatorManager.startHandshake(deviceId);
      final msg2 = responderManager
          .processHandshakeMessage(deviceId, msg1)
          .response!;
      final msg3 = initiatorManager
          .processHandshakeMessage(deviceId, msg2)
          .response!;
      responderManager.processHandshakeMessage(deviceId, msg3);

      final garbage = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      final result = responderManager.decrypt(garbage, deviceId);
      expect(result, isNull);
    });

    testWidgets('removeSession cleans up handshake state',
        (WidgetTester tester) async {
      const deviceId = 'test_device_5';

      initiatorManager.startHandshake(deviceId);
      expect(initiatorManager.hasSession(deviceId), isFalse);

      final msg1 = initiatorManager.startHandshake(deviceId);
      final msg2 = responderManager
          .processHandshakeMessage(deviceId, msg1)
          .response!;
      initiatorManager.processHandshakeMessage(deviceId, msg2);
      expect(initiatorManager.hasSession(deviceId), isTrue);

      initiatorManager.removeSession(deviceId);
      expect(initiatorManager.hasSession(deviceId), isFalse);
    });

    testWidgets('getRemotePubKey returns null before handshake complete',
        (WidgetTester tester) async {
      const deviceId = 'test_device_6';
      initiatorManager.startHandshake(deviceId);
      final result = initiatorManager.getRemotePubKey(deviceId);
      expect(result, isNull);
    });

    testWidgets('clear removes all sessions and pending handshakes',
        (WidgetTester tester) async {
      initiatorManager.startHandshake('device_1');
      initiatorManager.startHandshake('device_2');

      initiatorManager.clear();

      expect(initiatorManager.hasSession('device_1'), isFalse);
      expect(initiatorManager.hasSession('device_2'), isFalse);
    });

    testWidgets('Multiple peers with independent sessions',
        (WidgetTester tester) async {
      const device1 = 'device_1';
      const device2 = 'device_2';

      final msg1a = initiatorManager.startHandshake(device1);
      final msg2a = responderManager
          .processHandshakeMessage(device1, msg1a)
          .response!;
      final msg3a = initiatorManager
          .processHandshakeMessage(device1, msg2a)
          .response!;
      responderManager.processHandshakeMessage(device1, msg3a);

      final msg1b = initiatorManager.startHandshake(device2);
      final msg2b = responderManager
          .processHandshakeMessage(device2, msg1b)
          .response!;
      final msg3b = initiatorManager
          .processHandshakeMessage(device2, msg2b)
          .response!;
      responderManager.processHandshakeMessage(device2, msg3b);

      expect(initiatorManager.hasSession(device1), isTrue);
      expect(initiatorManager.hasSession(device2), isTrue);

      final plaintext1 = Uint8List.fromList([1, 2, 3]);
      final plaintext2 = Uint8List.fromList([4, 5, 6]);

      final cipher1 = initiatorManager.encrypt(plaintext1, device1);
      final cipher2 = initiatorManager.encrypt(plaintext2, device2);

      final decrypt1 = responderManager.decrypt(cipher1!, device1);
      final decrypt2 = responderManager.decrypt(cipher2!, device2);

      expect(decrypt1, equals(plaintext1));
      expect(decrypt2, equals(plaintext2));
    });
  });

  // ==========================================================================
  // 3. E2E Noise Handshake (from e2e_noise_handshake_test.dart) — 14 tests
  // ==========================================================================

  group('E2E Noise Handshake', () {
    testWidgets('complete 3-message handshake exchange',
        (WidgetTester tester) async {
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
      expect(msg1, isNotEmpty);

      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      expect(msg2, isNotEmpty);

      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      expect(initiator.isComplete, isTrue);

      responder.readMessage(msg3);
      expect(responder.isComplete, isTrue);

      expect(
          initiator.remoteStaticPublic, equals(responderStaticPair.publicKey));
      expect(
          responder.remoteStaticPublic, equals(initiatorStaticPair.publicKey));
    });

    testWidgets('handshake establishes matching session keys',
        (WidgetTester tester) async {
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
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      expect(initiatorSession, isNotNull);
      expect(responderSession, isNotNull);
    });

    testWidgets('session encrypt and decrypt round-trip',
        (WidgetTester tester) async {
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
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      final plaintext = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final ciphertext = initiatorSession.encrypt(plaintext);

      expect(ciphertext, isNotEmpty);
      expect(ciphertext, isNot(plaintext));

      final decrypted = responderSession.decrypt(ciphertext);
      expect(decrypted, equals(plaintext));
    });

    testWidgets('bidirectional encryption works',
        (WidgetTester tester) async {
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
      responder.readMessage(msg1);
      final msg2 = responder.writeMessage();
      initiator.readMessage(msg2);
      final msg3 = initiator.writeMessage();
      responder.readMessage(msg3);

      final initiatorSession = NoiseSession.fromHandshake(
        initiator,
        remotePeerId: responderStaticPair.publicKey,
      );

      final responderSession = NoiseSession.fromHandshake(
        responder,
        remotePeerId: initiatorStaticPair.publicKey,
      );

      final msg1Plaintext = Uint8List.fromList([0x10, 0x20]);
      final msg1Ciphertext = initiatorSession.encrypt(msg1Plaintext);
      final msg1Decrypted = responderSession.decrypt(msg1Ciphertext);
      expect(msg1Decrypted, equals(msg1Plaintext));

      final msg2Plaintext = Uint8List.fromList([0x30, 0x40]);
      final msg2Ciphertext = responderSession.encrypt(msg2Plaintext);
      final msg2Decrypted = initiatorSession.decrypt(msg2Ciphertext);
      expect(msg2Decrypted, equals(msg2Plaintext));
    });

    testWidgets('multiple encrypted messages maintain nonce separation',
        (WidgetTester tester) async {
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
        ciphertexts.add(initiatorSession.encrypt(plaintext));
      }

      expect(ciphertexts[0], isNot(ciphertexts[1]));
      expect(ciphertexts[1], isNot(ciphertexts[2]));

      for (var i = 0; i < msgs.length; i++) {
        final decrypted = responderSession.decrypt(ciphertexts[i]);
        expect(decrypted, equals(msgs[i]));
      }
    });

    testWidgets('encrypted message tampering is detected',
        (WidgetTester tester) async {
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

      final tampered = Uint8List.fromList(ciphertext);
      tampered[0] ^= 0x01;

      expect(
        () => responderSession.decrypt(tampered),
        anyOf(throwsException, isNull),
      );
    });

    testWidgets('session manager orchestrates full handshake',
        (WidgetTester tester) async {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();

      final manager1 = NoiseSessionManager(
        myStaticPrivKey: keyPair1.privateKey,
        myStaticPubKey: keyPair1.publicKey,
        localSigningPublicKey: Uint8List(32),
      );

      final manager2 = NoiseSessionManager(
        myStaticPrivKey: keyPair2.privateKey,
        myStaticPubKey: keyPair2.publicKey,
        localSigningPublicKey: Uint8List(32),
      );

      const deviceId = 'device-test';

      final msg1 = manager1.startHandshake(deviceId);
      expect(msg1, isNotEmpty);

      var result = manager2.processHandshakeMessage(deviceId, msg1);
      expect(result.response, isNotEmpty);
      expect(result.remotePubKey, isNull);

      result = manager1.processHandshakeMessage(deviceId, result.response!);
      expect(result.response, isNotEmpty);

      result = manager2.processHandshakeMessage(deviceId, result.response!);
      expect(result.remotePubKey, isNotNull);
    });

    testWidgets('static key pair is X25519 (32-byte keys)',
        (WidgetTester tester) async {
      final keyPair = KeyGenerator.generateStaticKeyPair();
      expect(keyPair.privateKey.length, equals(32));
      expect(keyPair.publicKey.length, equals(32));
    });

    testWidgets('session key material is sufficient for ChaCha20',
        (WidgetTester tester) async {
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

      final plaintext = Uint8List.fromList([0x01, 0x02]);
      final ciphertext = initiatorSession.encrypt(plaintext);
      final decrypted = responderSession.decrypt(ciphertext);

      expect(decrypted, equals(plaintext));
    });
  });

  // ==========================================================================
  // 4. BLE Transport Handshake (from ble_transport_handshake_test.dart) — 16 tests
  // ==========================================================================

  group('BLE Transport Handshake Flow', () {
    late MockIdentityManagerSimple identityManager;
    late NoiseSessionManager noiseSessionManager;

    setUp(() {
      identityManager = MockIdentityManagerSimple();
      noiseSessionManager = NoiseSessionManager(
        myStaticPrivKey: identityManager.privateKey,
        myStaticPubKey: identityManager.publicKey,
        localSigningPublicKey: Uint8List(32),
      );
    });

    testWidgets('startHandshake generates message 1',
        (WidgetTester tester) async {
      final message1 = noiseSessionManager.startHandshake('device-001');
      expect(message1, isNotEmpty);
    });

    testWidgets('processHandshakeMessage handles message 1 as responder',
        (WidgetTester tester) async {
      final noiseInitiator = NoiseSessionManager(
        myStaticPrivKey: identityManager.privateKey,
        myStaticPubKey: identityManager.publicKey,
        localSigningPublicKey: Uint8List(32),
      );

      final message1 = noiseInitiator.startHandshake('peer-device');
      final result =
          noiseSessionManager.processHandshakeMessage('device-002', message1);

      expect(result.response, isNotEmpty);
      expect(result.remotePubKey, isNull);
    });

    testWidgets('handshake state transitions through 3 messages',
        (WidgetTester tester) async {
      final responderNoiseManager = NoiseSessionManager(
        myStaticPrivKey: identityManager.privateKey,
        myStaticPubKey: identityManager.publicKey,
        localSigningPublicKey: Uint8List(32),
      );

      final message1 = noiseSessionManager.startHandshake('device-003');
      expect(message1, isNotEmpty);

      final step2 = responderNoiseManager.processHandshakeMessage(
          'device-003', message1);
      expect(step2.response, isNotEmpty);
      expect(step2.remotePubKey, isNull);
    });

    testWidgets('different device IDs maintain separate states',
        (WidgetTester tester) async {
      final msg1_device1 = noiseSessionManager.startHandshake('device-005');
      final msg1_device2 = noiseSessionManager.startHandshake('device-006');

      expect(msg1_device1, isNotEmpty);
      expect(msg1_device2, isNotEmpty);
    });

    testWidgets('plaintext broadcast packet accepted before handshake',
        (WidgetTester tester) async {
      final payload = BinaryProtocol.encodeChatPayload('Hello everyone!');
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xFF),
        payload: payload,
      );

      final encoded = packet.encode();
      final decoded = FluxonPacket.decode(encoded, hasSignature: false);

      expect(decoded, isNotNull);
      expect(decoded!.type, equals(MessageType.chat));
      expect(BinaryProtocol.decodeChatPayload(decoded.payload),
          equals('Hello everyone!'));
    });

    testWidgets('plaintext location updates accepted',
        (WidgetTester tester) async {
      final payload = BinaryProtocol.encodeLocationPayload(
        latitude: 40.7128,
        longitude: -74.0060,
        accuracy: 5.0,
      );

      final packet = BinaryProtocol.buildPacket(
        type: MessageType.locationUpdate,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xCC),
        payload: payload,
      );

      final encoded = packet.encode();
      final decoded = FluxonPacket.decode(encoded, hasSignature: false);

      expect(decoded, isNotNull);
      expect(decoded!.type, equals(MessageType.locationUpdate));

      final loc = BinaryProtocol.decodeLocationPayload(decoded.payload);
      expect(loc!.latitude, closeTo(40.7128, 0.001));
    });

    testWidgets('plaintext emergency alerts accepted',
        (WidgetTester tester) async {
      final payload = BinaryProtocol.encodeEmergencyPayload(
        alertType: 1,
        latitude: 37.7749,
        longitude: -122.4194,
        message: 'Emergency!',
      );

      final packet = BinaryProtocol.buildPacket(
        type: MessageType.emergencyAlert,
        sourceId: Uint8List(32)..fillRange(0, 32, 0xDD),
        payload: payload,
      );

      final encoded = packet.encode();
      final decoded = FluxonPacket.decode(encoded, hasSignature: false);

      expect(decoded, isNotNull);
      expect(decoded!.type, equals(MessageType.emergencyAlert));

      final emergency =
          BinaryProtocol.decodeEmergencyPayload(decoded.payload);
      expect(emergency!.message, equals('Emergency!'));
    });
  });

  // ==========================================================================
  // 5. E2E Relay Encrypted (from e2e_relay_encrypted_test.dart) — 12 tests
  // ==========================================================================

  group('E2E Relay Encrypted', () {
    testWidgets('mesh service forwards encrypted application packets',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0xAA);
      final remotePeerId = Uint8List(32)..fillRange(0, 32, 0xBB);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final payload =
            BinaryProtocol.encodeChatPayload('relay test message');
        final packet = BinaryProtocol.buildPacket(
          type: MessageType.chat,
          sourceId: remotePeerId,
          payload: payload,
        );

        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        rawTransport.simulateIncomingPacket(packet);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, isNotEmpty);
        expect(received.first.type, equals(MessageType.chat));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('location updates relay correctly',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0xCC);
      final remotePeerId = Uint8List(32)..fillRange(0, 32, 0xDD);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final payload = BinaryProtocol.encodeLocationPayload(
          latitude: 40.7128,
          longitude: -74.0060,
          accuracy: 5.0,
        );

        final packet = BinaryProtocol.buildPacket(
          type: MessageType.locationUpdate,
          sourceId: remotePeerId,
          payload: payload,
        );

        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        rawTransport.simulateIncomingPacket(packet);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, isNotEmpty);
        expect(received.first.type, equals(MessageType.locationUpdate));

        final decodedLoc =
            BinaryProtocol.decodeLocationPayload(received.first.payload);
        expect(decodedLoc!.latitude, closeTo(40.7128, 0.001));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('emergency alerts relay without loss',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0xEE);
      final remotePeerId = Uint8List(32)..fillRange(0, 32, 0xFF);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final payload = BinaryProtocol.encodeEmergencyPayload(
          alertType: 1,
          latitude: 37.7749,
          longitude: -122.4194,
          message: 'Emergency SOS',
        );

        final packet = BinaryProtocol.buildPacket(
          type: MessageType.emergencyAlert,
          sourceId: remotePeerId,
          payload: payload,
        );

        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        rawTransport.simulateIncomingPacket(packet);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, isNotEmpty);
        expect(received.first.type, equals(MessageType.emergencyAlert));

        final decodedEmergency =
            BinaryProtocol.decodeEmergencyPayload(received.first.payload);
        expect(decodedEmergency!.message, equals('Emergency SOS'));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('multiple packets relay in sequence',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0x11);
      final remotePeerId = Uint8List(32)..fillRange(0, 32, 0x22);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        for (var i = 0; i < 3; i++) {
          final payload = BinaryProtocol.encodeChatPayload('message $i');
          final packet = BinaryProtocol.buildPacket(
            type: MessageType.chat,
            sourceId: remotePeerId,
            payload: payload,
          );
          rawTransport.simulateIncomingPacket(packet);
          await Future.delayed(const Duration(milliseconds: 25));
        }

        expect(received.length, equals(3));
        for (var i = 0; i < 3; i++) {
          expect(
            BinaryProtocol.decodeChatPayload(received[i].payload),
            equals('message $i'),
          );
        }
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('broadcast packets relay correctly',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0x88);
      final senderId = Uint8List(32)..fillRange(0, 32, 0x99);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final payload = BinaryProtocol.encodeChatPayload('broadcast');
        final packet = FluxonPacket(
          type: MessageType.chat,
          ttl: 7,
          flags: 0,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          sourceId: senderId,
          destId: Uint8List(32),
          payload: payload,
          signature: null,
        );

        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        rawTransport.simulateIncomingPacket(packet);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, isNotEmpty);
        expect(
          BinaryProtocol.decodeChatPayload(received.first.payload),
          equals('broadcast'),
        );
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('packet payload integrity maintained through relay',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0xDD);
      final senderId = Uint8List(32)..fillRange(0, 32, 0xEE);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final originalMessage =
            'Long message with special chars: !@#\$%^&*()';
        final payload = BinaryProtocol.encodeChatPayload(originalMessage);
        final packet = BinaryProtocol.buildPacket(
          type: MessageType.chat,
          sourceId: senderId,
          payload: payload,
        );

        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        rawTransport.simulateIncomingPacket(packet);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, isNotEmpty);
        final relayedMessage =
            BinaryProtocol.decodeChatPayload(received.first.payload);
        expect(relayedMessage, equals(originalMessage));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('mesh service handles many packets efficiently',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0xFF);
      final senderId = Uint8List(32)..fillRange(0, 32, 0x00);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        const packetCount = 50;
        for (var i = 0; i < packetCount; i++) {
          final payload = BinaryProtocol.encodeChatPayload('packet $i');
          final packet = BinaryProtocol.buildPacket(
            type: MessageType.chat,
            sourceId: senderId,
            payload: payload,
          );
          rawTransport.simulateIncomingPacket(packet);
        }

        await Future.delayed(const Duration(milliseconds: 200));

        expect(received.length, equals(packetCount));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('relay maintains packet ordering',
        (WidgetTester tester) async {
      final myPeerId = Uint8List(32)..fillRange(0, 32, 0x01);
      final senderId = Uint8List(32)..fillRange(0, 32, 0x02);

      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final received = <FluxonPacket>[];
        meshService.onPacketReceived.listen(received.add);

        const packetCount = 20;
        for (var i = 0; i < packetCount; i++) {
          final payload = BinaryProtocol.encodeChatPayload('msg_$i');
          final packet = BinaryProtocol.buildPacket(
            type: MessageType.chat,
            sourceId: senderId,
            payload: payload,
          );
          rawTransport.simulateIncomingPacket(packet);
          await Future.delayed(const Duration(milliseconds: 5));
        }

        await Future.delayed(const Duration(milliseconds: 50));

        expect(received.length, equals(packetCount));

        for (var i = 0; i < packetCount; i++) {
          final msg = BinaryProtocol.decodeChatPayload(received[i].payload);
          expect(msg, equals('msg_$i'));
        }
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });
  });

  // ==========================================================================
  // 6. MeshService Transport delegates (from mesh_service_test.dart) — 2 tests
  // ==========================================================================

  group('MeshService Transport delegates (requires sodium)', () {
    testWidgets('delegates broadcastPacket to raw transport',
        (WidgetTester tester) async {
      final myPeerId = makePeerId(0xAA);
      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final packet = buildTestPacket(
          type: MessageType.chat,
          sourceId: myPeerId,
        );

        rawTransport.broadcastedPackets.clear();
        await meshService.broadcastPacket(packet);

        expect(rawTransport.broadcastedPackets, hasLength(1));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });

    testWidgets('delegates sendPacket to raw transport',
        (WidgetTester tester) async {
      final myPeerId = makePeerId(0xAA);
      final remotePeer = makePeerId(0xBB);
      final rawTransport = StubTransport(myPeerId: myPeerId);
      final identityManager = MockIdentityManager();
      final meshService = MeshService(
        transport: rawTransport,
        myPeerId: myPeerId,
        identityManager: identityManager,
      );

      await meshService.start();

      try {
        final packet = buildTestPacket(
          type: MessageType.chat,
          sourceId: myPeerId,
        );

        await meshService.sendPacket(packet, remotePeer);

        expect(rawTransport.sentPackets, hasLength(1));
        expect(rawTransport.sentPackets.first.$1.type,
            equals(MessageType.chat));
        expect(rawTransport.sentPackets.first.$2, equals(remotePeer));
      } finally {
        await meshService.stop();
        rawTransport.dispose();
      }
    });
  });

  // ==========================================================================
  // 7. Ed25519 Signatures (Phase 3 specific) — 4 tests
  // ==========================================================================

  group('Ed25519 Signatures', () {
    testWidgets('generate signing key pair', (WidgetTester tester) async {
      final keyPair = Signatures.generateSigningKeyPair();
      expect(keyPair.publicKey.length, equals(32));
      expect(keyPair.privateKey.length, equals(64));
    });

    testWidgets('sign and verify round-trip', (WidgetTester tester) async {
      final keyPair = Signatures.generateSigningKeyPair();
      final message = Uint8List.fromList([1, 2, 3, 4, 5]);
      final signature = Signatures.sign(message, keyPair.privateKey);

      expect(signature.length, equals(64));

      final valid = Signatures.verify(message, signature, keyPair.publicKey);
      expect(valid, isTrue);
    });

    testWidgets('verify rejects tampered message',
        (WidgetTester tester) async {
      final keyPair = Signatures.generateSigningKeyPair();
      final message = Uint8List.fromList([1, 2, 3, 4, 5]);
      final signature = Signatures.sign(message, keyPair.privateKey);

      final tampered = Uint8List.fromList(message);
      tampered[0] ^= 0xFF;

      final valid = Signatures.verify(tampered, signature, keyPair.publicKey);
      expect(valid, isFalse);
    });

    testWidgets('verify rejects wrong key', (WidgetTester tester) async {
      final keyPair1 = Signatures.generateSigningKeyPair();
      final keyPair2 = Signatures.generateSigningKeyPair();
      final message = Uint8List.fromList([1, 2, 3, 4, 5]);
      final signature = Signatures.sign(message, keyPair1.privateKey);

      final valid = Signatures.verify(message, signature, keyPair2.publicKey);
      expect(valid, isFalse);
    });
  });

  // ==========================================================================
  // 8. Signing key distribution via Noise handshake (Phase 3) — 2 tests
  // ==========================================================================

  group('Signing Key Distribution via Noise', () {
    testWidgets('signing keys exchanged during handshake',
        (WidgetTester tester) async {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();
      final signingPair1 = Signatures.generateSigningKeyPair();
      final signingPair2 = Signatures.generateSigningKeyPair();

      final manager1 = NoiseSessionManager(
        myStaticPrivKey: keyPair1.privateKey,
        myStaticPubKey: keyPair1.publicKey,
        localSigningPublicKey: signingPair1.publicKey,
      );

      final manager2 = NoiseSessionManager(
        myStaticPrivKey: keyPair2.privateKey,
        myStaticPubKey: keyPair2.publicKey,
        localSigningPublicKey: signingPair2.publicKey,
      );

      const deviceId = 'signing-key-test';

      // Complete handshake
      final msg1 = manager1.startHandshake(deviceId);
      final r1 = manager2.processHandshakeMessage(deviceId, msg1);
      final r2 = manager1.processHandshakeMessage(deviceId, r1.response!);
      final r3 = manager2.processHandshakeMessage(deviceId, r2.response!);

      // Both should have completed
      expect(r2.remotePubKey ?? r3.remotePubKey, isNotNull);

      // Signing keys should be retrievable
      final key1FromManager2 = manager2.getSigningPublicKey(deviceId);
      final key2FromManager1 = manager1.getSigningPublicKey(deviceId);

      expect(key1FromManager2, isNotNull);
      expect(key2FromManager1, isNotNull);
      expect(key1FromManager2, equals(signingPair1.publicKey));
      expect(key2FromManager1, equals(signingPair2.publicKey));
    });

    testWidgets('removeSession clears signing keys',
        (WidgetTester tester) async {
      final keyPair1 = KeyGenerator.generateStaticKeyPair();
      final keyPair2 = KeyGenerator.generateStaticKeyPair();
      final signingPair1 = Signatures.generateSigningKeyPair();
      final signingPair2 = Signatures.generateSigningKeyPair();

      final manager1 = NoiseSessionManager(
        myStaticPrivKey: keyPair1.privateKey,
        myStaticPubKey: keyPair1.publicKey,
        localSigningPublicKey: signingPair1.publicKey,
      );

      final manager2 = NoiseSessionManager(
        myStaticPrivKey: keyPair2.privateKey,
        myStaticPubKey: keyPair2.publicKey,
        localSigningPublicKey: signingPair2.publicKey,
      );

      const deviceId = 'signing-cleanup-test';

      // Complete handshake
      final msg1 = manager1.startHandshake(deviceId);
      final r1 = manager2.processHandshakeMessage(deviceId, msg1);
      final r2 = manager1.processHandshakeMessage(deviceId, r1.response!);
      manager2.processHandshakeMessage(deviceId, r2.response!);

      // Remove session
      manager1.removeSession(deviceId);
      expect(manager1.getSigningPublicKey(deviceId), isNull);
    });
  });
}
