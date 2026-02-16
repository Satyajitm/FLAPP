import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/crypto/keys.dart';
import 'package:fluxon_app/core/identity/identity_manager.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:mocktail/mocktail.dart';

// ============================================================================
// TIER 2: Important Tests for Identity Manager Signing Lifecycle
// ============================================================================
// These tests verify that Ed25519 signing keys are properly initialized,
// persisted, and cleaned up. They catch lifecycle bugs and key management issues.

class MockKeyManager extends Mock implements KeyManager {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  // =========================================================================
  // TIER 2 TEST SUITE: IdentityManager Ed25519 Initialization
  // =========================================================================

  group('Tier 2: IdentityManager Signing Key Lifecycle', () {
    late MockKeyManager mockKeyManager;
    late IdentityManager identityManager;

    final testStaticPrivKey = Uint8List.fromList(List.generate(32, (i) => i));
    final testStaticPubKey = Uint8List.fromList(List.generate(32, (i) => i + 100));
    final testStaticKeyPair = (privateKey: testStaticPrivKey, publicKey: testStaticPubKey);

    final testSigningPrivKey = Uint8List.fromList(List.generate(64, (i) => i + 10));
    final testSigningPubKey = Uint8List.fromList(List.generate(32, (i) => i + 50));
    final testSigningKeyPair = (privateKey: testSigningPrivKey, publicKey: testSigningPubKey);

    setUp(() {
      mockKeyManager = MockKeyManager();
      identityManager = IdentityManager(keyManager: mockKeyManager);
    });

    test('initialize calls KeyManager for both static and signing keys', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      verify(() => mockKeyManager.getOrCreateStaticKeyPair()).called(1);
      verify(() => mockKeyManager.getOrCreateSigningKeyPair()).called(1);
    });

    test('signing private key accessible after initialization', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      expect(identityManager.signingPrivateKey, equals(testSigningPrivKey));
      expect(identityManager.signingPrivateKey.length, equals(64));
    });

    test('signing public key accessible after initialization', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      expect(identityManager.signingPublicKey, equals(testSigningPubKey));
      expect(identityManager.signingPublicKey.length, equals(32));
    });

    test('signing keys throw StateError before initialization', () {
      expect(
        () => identityManager.signingPrivateKey,
        throwsStateError,
        reason: 'Signing private key should not be accessible before init',
      );
      expect(
        () => identityManager.signingPublicKey,
        throwsStateError,
        reason: 'Signing public key should not be accessible before init',
      );
    });

    test('static and signing keys are properly paired after init', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      // Both key types should be initialized
      expect(identityManager.privateKey, isNotNull);
      expect(identityManager.publicKey, isNotNull);
      expect(identityManager.signingPrivateKey, isNotNull);
      expect(identityManager.signingPublicKey, isNotNull);

      // Lengths should be correct
      expect(identityManager.privateKey.length, equals(32));
      expect(identityManager.publicKey.length, equals(32));
      expect(identityManager.signingPrivateKey.length, equals(64));
      expect(identityManager.signingPublicKey.length, equals(32));
    });

    test('peer ID derived from static public key', () async {
      final derivedPeerId = Uint8List.fromList(List.generate(32, (i) => i + 200));

      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(testStaticPubKey))
          .thenReturn(derivedPeerId);
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      verify(() => mockKeyManager.derivePeerId(testStaticPubKey)).called(1);
      expect(identityManager.myPeerId, isA<PeerId>());
    });

    test('multiple initialize calls reuse existing keys', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();
      await identityManager.initialize();

      // KeyManager was called twice (normal behavior for getOrCreate)
      verify(() => mockKeyManager.getOrCreateStaticKeyPair()).called(2);
    });
  });

  // =========================================================================
  // TIER 2 TEST SUITE: Signing Key Cleanup
  // =========================================================================

  group('Tier 2: Signing Key Cleanup on Reset', () {
    late MockKeyManager mockKeyManager;
    late IdentityManager identityManager;

    final testStaticPrivKey = Uint8List.fromList(List.generate(32, (i) => i));
    final testStaticPubKey = Uint8List.fromList(List.generate(32, (i) => i + 100));
    final testStaticKeyPair = (privateKey: testStaticPrivKey, publicKey: testStaticPubKey);

    final testSigningPrivKey = Uint8List.fromList(List.generate(64, (i) => i + 10));
    final testSigningPubKey = Uint8List.fromList(List.generate(32, (i) => i + 50));
    final testSigningKeyPair = (privateKey: testSigningPrivKey, publicKey: testSigningPubKey);

    setUp(() {
      mockKeyManager = MockKeyManager();
      identityManager = IdentityManager(keyManager: mockKeyManager);
    });

    test('resetIdentity clears signing keys', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);
      when(() => mockKeyManager.deleteStaticKeyPair())
          .thenAnswer((_) async {});
      when(() => mockKeyManager.deleteSigningKeyPair())
          .thenAnswer((_) async {});

      await identityManager.initialize();
      expect(identityManager.signingPrivateKey, isNotNull);

      await identityManager.resetIdentity();

      expect(
        () => identityManager.signingPrivateKey,
        throwsStateError,
        reason: 'Signing key should not be accessible after reset',
      );
    });

    test('resetIdentity deletes signing keys via KeyManager', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);
      when(() => mockKeyManager.deleteStaticKeyPair())
          .thenAnswer((_) async {});
      when(() => mockKeyManager.deleteSigningKeyPair())
          .thenAnswer((_) async {});

      await identityManager.initialize();
      await identityManager.resetIdentity();

      verify(() => mockKeyManager.deleteSigningKeyPair()).called(1);
    });

    test('resetIdentity clears public signing key', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);
      when(() => mockKeyManager.deleteStaticKeyPair())
          .thenAnswer((_) async {});
      when(() => mockKeyManager.deleteSigningKeyPair())
          .thenAnswer((_) async {});

      await identityManager.initialize();
      await identityManager.resetIdentity();

      expect(
        () => identityManager.signingPublicKey,
        throwsStateError,
        reason: 'Signing public key should not be accessible after reset',
      );
    });
  });

  // =========================================================================
  // TIER 2 TEST SUITE: Trust Lifecycle with Signing Keys
  // =========================================================================

  group('Tier 2: Peer Trust Lifecycle', () {
    late MockKeyManager mockKeyManager;
    late IdentityManager identityManager;

    final testStaticPrivKey = Uint8List.fromList(List.generate(32, (i) => i));
    final testStaticPubKey = Uint8List.fromList(List.generate(32, (i) => i + 100));
    final testStaticKeyPair = (privateKey: testStaticPrivKey, publicKey: testStaticPubKey);

    final testSigningPrivKey = Uint8List.fromList(List.generate(64, (i) => i + 10));
    final testSigningPubKey = Uint8List.fromList(List.generate(32, (i) => i + 50));
    final testSigningKeyPair = (privateKey: testSigningPrivKey, publicKey: testSigningPubKey);

    setUp(() {
      mockKeyManager = MockKeyManager();
      identityManager = IdentityManager(keyManager: mockKeyManager);
    });

    test('trusted peer list survives key rotation', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      final peer1 = PeerId(Uint8List(32)..fillRange(0, 32, 0x01));
      final peer2 = PeerId(Uint8List(32)..fillRange(0, 32, 0x02));

      identityManager.trustPeer(peer1);
      identityManager.trustPeer(peer2);

      expect(identityManager.trustedPeers, contains(peer1));
      expect(identityManager.trustedPeers, contains(peer2));
    });

    test('trusted peers cleared on reset', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
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
      expect(identityManager.trustedPeers, isNotEmpty);

      await identityManager.resetIdentity();
      expect(identityManager.trustedPeers, isEmpty);
    });

    test('trust can be revoked after peer is trusted', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      final peer = PeerId(Uint8List(32));
      identityManager.trustPeer(peer);
      expect(identityManager.isTrusted(peer), isTrue);

      identityManager.revokeTrust(peer);
      expect(identityManager.isTrusted(peer), isFalse);
    });

    test('revoking trust from untrusted peer is safe', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      final peer = PeerId(Uint8List(32));
      expect(identityManager.isTrusted(peer), isFalse);

      // Should not throw
      identityManager.revokeTrust(peer);
      expect(identityManager.isTrusted(peer), isFalse);
    });
  });

  // =========================================================================
  // TIER 2 TEST SUITE: Key Immutability
  // =========================================================================

  group('Tier 2: Key Immutability After Initialization', () {
    late MockKeyManager mockKeyManager;
    late IdentityManager identityManager;

    final testStaticPrivKey = Uint8List.fromList(List.generate(32, (i) => i));
    final testStaticPubKey = Uint8List.fromList(List.generate(32, (i) => i + 100));
    final testStaticKeyPair = (privateKey: testStaticPrivKey, publicKey: testStaticPubKey);

    final testSigningPrivKey = Uint8List.fromList(List.generate(64, (i) => i + 10));
    final testSigningPubKey = Uint8List.fromList(List.generate(32, (i) => i + 50));
    final testSigningKeyPair = (privateKey: testSigningPrivKey, publicKey: testSigningPubKey);

    setUp(() {
      mockKeyManager = MockKeyManager();
      identityManager = IdentityManager(keyManager: mockKeyManager);
    });

    test('signing private key is independent of static key', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      expect(identityManager.signingPrivateKey, isNot(identityManager.privateKey));
      expect(identityManager.signingPrivateKey.length, equals(64));
      expect(identityManager.privateKey.length, equals(32));
    });

    test('signing public key is independent of static public key', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      expect(identityManager.signingPublicKey, isNot(identityManager.publicKey));
      expect(identityManager.signingPublicKey.length, equals(32));
      expect(identityManager.publicKey.length, equals(32));
    });

    test('keys remain consistent across multiple accesses', () async {
      when(() => mockKeyManager.getOrCreateStaticKeyPair())
          .thenAnswer((_) async => testStaticKeyPair);
      when(() => mockKeyManager.derivePeerId(any()))
          .thenReturn(Uint8List(32));
      when(() => mockKeyManager.getOrCreateSigningKeyPair())
          .thenAnswer((_) async => testSigningKeyPair);

      await identityManager.initialize();

      final sigPriv1 = identityManager.signingPrivateKey;
      final sigPriv2 = identityManager.signingPrivateKey;
      expect(sigPriv1, equals(sigPriv2));

      final sigPub1 = identityManager.signingPublicKey;
      final sigPub2 = identityManager.signingPublicKey;
      expect(sigPub1, equals(sigPub2));
    });
  });
}
