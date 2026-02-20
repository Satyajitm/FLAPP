
import 'dart:typed_data';

import 'package:fluxon_app/core/crypto/keys.dart';
import 'package:fluxon_app/core/identity/identity_manager.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockKeyManager extends Mock implements KeyManager {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  late IdentityManager identityManager;
  late MockKeyManager mockKeyManager;

  setUp(() {
    mockKeyManager = MockKeyManager();
    identityManager = IdentityManager(keyManager: mockKeyManager);
  });

  group('IdentityManager', () {
    final testPrivateKey = Uint8List.fromList(List.generate(32, (i) => i));
    final testPublicKey = Uint8List.fromList(List.generate(32, (i) => i + 100));
    final ({Uint8List privateKey, Uint8List publicKey}) testKeyPair = (privateKey: testPrivateKey, publicKey: testPublicKey);

    final testSigningPrivateKey = Uint8List.fromList(List.generate(64, (i) => i));
    final testSigningPublicKey = Uint8List.fromList(List.generate(32, (i) => i + 200));
    final ({Uint8List privateKey, Uint8List publicKey}) testSigningKeyPair = (privateKey: testSigningPrivateKey, publicKey: testSigningPublicKey);

    test('initialize loads keys and sets peer ID', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      expect(identityManager.privateKey, equals(testPrivateKey));
      expect(identityManager.publicKey, equals(testPublicKey));
      expect(identityManager.myPeerId, isNotNull);
    });

    test('accessing keys before initialization throws StateError', () {
      expect(() => identityManager.privateKey, throwsStateError);
      expect(() => identityManager.publicKey, throwsStateError);
      expect(() => identityManager.myPeerId, throwsStateError);
    });

    test('trustPeer adds peer to trusted set', () {
      final peerId = PeerId(Uint8List(32));
      identityManager.trustPeer(peerId);
      expect(identityManager.isTrusted(peerId), isTrue);
    });

    test('revokeTrust removes peer from trusted set', () {
      final peerId = PeerId(Uint8List(32));
      identityManager.trustPeer(peerId);
      identityManager.revokeTrust(peerId);
      expect(identityManager.isTrusted(peerId), isFalse);
    });

    test('resetIdentity clears keys and trust', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);
      when(() => mockKeyManager.deleteStaticKeyPair())
          .thenAnswer((_) async {});
      when(() => mockKeyManager.deleteSigningKeyPair())
          .thenAnswer((_) async {});

      await identityManager.initialize();
      identityManager.trustPeer(PeerId(Uint8List(32)));

      await identityManager.resetIdentity();

      expect(() => identityManager.privateKey, throwsStateError);
      expect(identityManager.trustedPeers, isEmpty);
      verify(() => mockKeyManager.deleteStaticKeyPair()).called(1);
    });
  });
}
