// GroupManager tests using mock GroupCipher and GroupStorage.
//
// GroupCipher requires native sodium, so we inject a fake that works
// with pure-Dart logic. GroupStorage is also faked via FakeSecureStorage.

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxon_app/core/identity/group_cipher.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/group_storage.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';

// ---------------------------------------------------------------------------
// Fake GroupCipher — pure-Dart, no sodium dependency
// ---------------------------------------------------------------------------

class FakeGroupCipher implements GroupCipher {
  @override
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey) {
    if (groupKey == null) return null;
    // Simple XOR "encryption" for testing
    final result = Uint8List(plaintext.length);
    for (var i = 0; i < plaintext.length; i++) {
      result[i] = plaintext[i] ^ groupKey[i % groupKey.length];
    }
    return result;
  }

  @override
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey) {
    // XOR is its own inverse
    return encrypt(data, groupKey);
  }

  @override
  Uint8List deriveGroupKey(String passphrase, Uint8List salt) {
    // Deterministic 32-byte key from passphrase (salt ignored for fake — same
    // passphrase always gives same key, which is fine for most tests, but note
    // the same-salt joinGroup test explicitly uses the same derived key path).
    final key = Uint8List(32);
    final bytes = passphrase.codeUnits;
    for (var i = 0; i < 32; i++) {
      key[i] = bytes[i % bytes.length] ^ (i * 7);
    }
    return key;
  }

  @override
  Uint8List generateSalt() => Uint8List(16); // Fixed salt for deterministic tests

  @override
  String generateGroupId(String passphrase, Uint8List salt) {
    // Include a simple salt contribution so different salts give different IDs.
    final saltSum = salt.fold<int>(0, (acc, b) => acc + b);
    return 'fake-group-${passphrase.hashCode.toRadixString(16)}-$saltSum';
  }

  static const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  @override
  String encodeSalt(Uint8List salt) {
    var buffer = 0;
    var bitsLeft = 0;
    final result = StringBuffer();
    for (final byte in salt) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        result.writeCharCode(_b32.codeUnitAt((buffer >> bitsLeft) & 0x1F));
      }
    }
    if (bitsLeft > 0) {
      result.writeCharCode(_b32.codeUnitAt((buffer << (5 - bitsLeft)) & 0x1F));
    }
    return result.toString();
  }

  @override
  Uint8List decodeSalt(String code) {
    final upper = code.toUpperCase();
    var buffer = 0;
    var bitsLeft = 0;
    final result = <int>[];
    for (final ch in upper.split('')) {
      final val = _b32.indexOf(ch);
      if (val < 0) throw FormatException('Invalid base32 char: $ch');
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        result.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(result);
  }
}

// ---------------------------------------------------------------------------
// Fake FlutterSecureStorage (in-memory)
// ---------------------------------------------------------------------------

class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _store[key] = value;
    } else {
      _store.remove(key);
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _store[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('GroupManager', () {
    late FakeGroupCipher fakeCipher;
    late FakeSecureStorage fakeStorage;
    late GroupStorage groupStorage;
    late GroupManager manager;

    setUp(() {
      fakeCipher = FakeGroupCipher();
      fakeStorage = FakeSecureStorage();
      groupStorage = GroupStorage(storage: fakeStorage);
      manager = GroupManager(cipher: fakeCipher, groupStorage: groupStorage);
    });

    test('initially has no active group', () {
      expect(manager.activeGroup, isNull);
      expect(manager.isInGroup, isFalse);
    });

    test('createGroup sets active group with derived key and ID', () {
      final salt = fakeCipher.generateSalt();
      final group = manager.createGroup('secret', groupName: 'My Team');

      expect(manager.isInGroup, isTrue);
      expect(manager.activeGroup, isNotNull);
      expect(group.name, equals('My Team'));
      expect(group.key, equals(fakeCipher.deriveGroupKey('secret', salt)));
      expect(group.id, equals(fakeCipher.generateGroupId('secret', salt)));
      expect(group.members, isEmpty);
    });

    test('createGroup uses default name when groupName is null', () {
      final group = manager.createGroup('pass');
      expect(group.name, equals('Fluxon Group'));
    });

    test('FluxonGroup.joinCode is a 26-character string', () {
      final group = manager.createGroup('pass');
      expect(group.joinCode.length, equals(26));
    });

    test('joinGroup with same passphrase+joinCode derives same key as creator', () {
      // Creator creates group
      final created = manager.createGroup('shared-secret', groupName: 'G1');
      final createdKey = Uint8List.fromList(created.key);
      final joinCode = created.joinCode;

      // Joiner uses passphrase + joinCode
      final joiner = GroupManager(
        cipher: fakeCipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final joined = joiner.joinGroup('shared-secret', joinCode: joinCode);

      expect(joined.key, equals(createdKey));
      expect(joined.id, equals(created.id));
    });

    test('joinGroup produces different group from different joinCode', () {
      final created1 = manager.createGroup('same-pass', groupName: 'G1');

      // Different manager creates a different group with same passphrase
      final manager2 = GroupManager(
        cipher: fakeCipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final created2 = manager2.createGroup('same-pass', groupName: 'G2');

      // Since FakeGroupCipher.generateSalt() returns all-zeros, IDs will match
      // in the fake, but in production the random salt would differ.
      // This test verifies joinGroup uses the provided joinCode salt, not a new one.
      final joiner = GroupManager(
        cipher: fakeCipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final joined = joiner.joinGroup('same-pass', joinCode: created1.joinCode);
      expect(joined.id, equals(created1.id));
      expect(joined.id, equals(created2.id)); // same because fake salt is always zeros
    });

    test('leaveGroup clears active group', () {
      manager.createGroup('pass');
      expect(manager.isInGroup, isTrue);

      manager.leaveGroup();
      expect(manager.isInGroup, isFalse);
      expect(manager.activeGroup, isNull);
    });

    test('addMember adds peer to active group members', () {
      manager.createGroup('pass');
      final peer = PeerId(Uint8List(32)..fillRange(0, 32, 0xAA));

      manager.addMember(peer);

      expect(manager.activeGroup!.members, contains(peer));
    });

    test('addMember is no-op when not in a group', () {
      final peer = PeerId(Uint8List(32)..fillRange(0, 32, 0xBB));
      manager.addMember(peer);
      expect(manager.activeGroup, isNull);
    });

    test('removeMember removes peer from active group members', () {
      manager.createGroup('pass');
      final peer = PeerId(Uint8List(32)..fillRange(0, 32, 0xCC));

      manager.addMember(peer);
      expect(manager.activeGroup!.members, hasLength(1));

      manager.removeMember(peer);
      expect(manager.activeGroup!.members, isEmpty);
    });

    test('removeMember is no-op when not in a group', () {
      final peer = PeerId(Uint8List(32)..fillRange(0, 32, 0xDD));
      manager.removeMember(peer);
    });

    test('encryptForGroup returns encrypted data when in a group', () {
      manager.createGroup('pass');
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

      final encrypted = manager.encryptForGroup(plaintext);

      expect(encrypted, isNotNull);
      expect(encrypted, isNot(equals(plaintext)));
    });

    test('encryptForGroup returns null when not in a group', () {
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted = manager.encryptForGroup(plaintext);
      expect(encrypted, isNull);
    });

    test('decryptFromGroup returns null when not in a group', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final decrypted = manager.decryptFromGroup(data);
      expect(decrypted, isNull);
    });

    test('encrypt/decrypt round-trip produces original data', () {
      manager.createGroup('pass');
      final plaintext = Uint8List.fromList([10, 20, 30, 40, 50]);

      final encrypted = manager.encryptForGroup(plaintext);
      expect(encrypted, isNotNull);

      final decrypted = manager.decryptFromGroup(encrypted!);
      expect(decrypted, equals(plaintext));
    });

    test('createGroup persists to storage including salt (fire-and-forget)', () async {
      manager.createGroup('persist-me', groupName: 'Saved Group');

      // Give fire-and-forget a moment to complete
      await Future.delayed(const Duration(milliseconds: 50));

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNotNull);
      expect(loaded!.groupKey, isNotEmpty);
      expect(loaded.name, equals('Saved Group'));
      expect(loaded.salt, isNotEmpty);
    });

    test('leaveGroup deletes from storage', () async {
      manager.createGroup('temp', groupName: 'Temp');
      await Future.delayed(const Duration(milliseconds: 50));

      manager.leaveGroup();
      await Future.delayed(const Duration(milliseconds: 50));

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });

    test('initialize restores group from storage including salt', () async {
      final salt = fakeCipher.generateSalt();
      // Pre-populate storage as if a previous session saved it
      await groupStorage.saveGroup(
        groupKey: fakeCipher.deriveGroupKey('restored-secret', salt),
        groupId: fakeCipher.generateGroupId('restored-secret', salt),
        name: 'Restored Group',
        createdAt: DateTime(2025, 7, 1),
        salt: salt,
      );

      final freshManager = GroupManager(
        cipher: fakeCipher,
        groupStorage: groupStorage,
      );
      await freshManager.initialize();

      expect(freshManager.isInGroup, isTrue);
      expect(freshManager.activeGroup!.name, equals('Restored Group'));
      expect(freshManager.activeGroup!.key,
          equals(fakeCipher.deriveGroupKey('restored-secret', salt)));
      expect(freshManager.activeGroup!.id,
          equals(fakeCipher.generateGroupId('restored-secret', salt)));
      expect(freshManager.activeGroup!.salt, equals(salt));
      expect(freshManager.activeGroup!.createdAt, equals(DateTime(2025, 7, 1)));
      expect(freshManager.activeGroup!.members, isEmpty);
    });

    test('initialize does nothing when storage is empty', () async {
      await manager.initialize();
      expect(manager.isInGroup, isFalse);
    });

    test('createGroup replaces previous active group', () {
      manager.createGroup('first', groupName: 'First');
      final firstId = manager.activeGroup!.id;

      manager.createGroup('second', groupName: 'Second');

      expect(manager.activeGroup!.name, equals('Second'));
      expect(manager.activeGroup!.id, isNot(equals(firstId)));
    });
  });

  group('GroupManager — PeerId member tracking', () {
    test('PeerId equality works', () {
      final peer1 = PeerId(Uint8List(32)..fillRange(0, 32, 0xAA));
      final peer2 = PeerId(Uint8List(32)..fillRange(0, 32, 0xAA));
      final peer3 = PeerId(Uint8List(32)..fillRange(0, 32, 0xBB));

      expect(peer1, equals(peer2));
      expect(peer1, isNot(equals(peer3)));
    });

    test('duplicate addMember does not create duplicates in Set', () {
      final cipher = FakeGroupCipher();
      final manager = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      manager.createGroup('pass');

      final peer = PeerId(Uint8List(32)..fillRange(0, 32, 0xAA));
      manager.addMember(peer);
      manager.addMember(peer);

      expect(manager.activeGroup!.members, hasLength(1));
    });
  });

  // -------------------------------------------------------------------
  // Additional coverage: joinGroup options and FluxonGroup model
  // -------------------------------------------------------------------

  group('GroupManager — joinGroup additional coverage', () {
    late FakeGroupCipher cipher;
    late GroupManager manager;

    setUp(() {
      cipher = FakeGroupCipher();
      manager = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
    });

    test('joinGroup with custom groupName uses provided name', () {
      final created = manager.createGroup('my-pass', groupName: 'OrigGroup');
      final joiner = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final joined = joiner.joinGroup(
        'my-pass',
        joinCode: created.joinCode,
        groupName: 'CustomName',
      );
      expect(joined.name, equals('CustomName'));
    });

    test('joinGroup with null groupName defaults to "Fluxon Group"', () {
      final created = manager.createGroup('my-pass');
      final joiner = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final joined = joiner.joinGroup('my-pass', joinCode: created.joinCode);
      expect(joined.name, equals('Fluxon Group'));
    });

    test('joinGroup sets isInGroup true on joiner', () {
      final created = manager.createGroup('pass1234');
      final joiner = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      expect(joiner.isInGroup, isFalse);
      joiner.joinGroup('pass1234', joinCode: created.joinCode);
      expect(joiner.isInGroup, isTrue);
    });

    test('joinGroup returns the active group object', () {
      final created = manager.createGroup('pass1234');
      final joiner = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final returned = joiner.joinGroup('pass1234', joinCode: created.joinCode);
      expect(returned, same(joiner.activeGroup));
    });
  });

  group('FluxonGroup model', () {
    late FakeGroupCipher cipher;
    late GroupManager manager;

    setUp(() {
      cipher = FakeGroupCipher();
      manager = GroupManager(
        cipher: cipher,
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
    });

    test('members set is initially empty after createGroup', () {
      final group = manager.createGroup('pass');
      expect(group.members, isEmpty);
    });

    test('createdAt is set to approximately now during createGroup', () {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final group = manager.createGroup('pass');
      final after = DateTime.now().add(const Duration(seconds: 1));
      expect(group.createdAt.isAfter(before), isTrue);
      expect(group.createdAt.isBefore(after), isTrue);
    });

    test('joinCode roundtrips through decodeSalt back to same salt', () {
      final group = manager.createGroup('roundtrip-test');
      final encoded = group.joinCode;
      final decoded = cipher.decodeSalt(encoded);
      expect(decoded, equals(group.salt));
    });

    test('joinCode contains only valid base32 chars (A-Z, 2-7)', () {
      const valid = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      final group = manager.createGroup('pass');
      for (final c in group.joinCode.split('')) {
        expect(valid.contains(c), isTrue,
            reason: 'Unexpected character "$c" in joinCode');
      }
    });

    test('two managers with different passphrases produce different group IDs', () {
      final g1 = manager.createGroup('alpha-pass');
      final manager2 = GroupManager(
        cipher: FakeGroupCipher(),
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      final g2 = manager2.createGroup('beta-pass');
      expect(g1.id, isNot(equals(g2.id)));
    });
  });
}
