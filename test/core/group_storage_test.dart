import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxon_app/core/identity/group_storage.dart';

// ---------------------------------------------------------------------------
// Fake FlutterSecureStorage for testing (in-memory)
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
  group('GroupStorage', () {
    late FakeSecureStorage fakeStorage;
    late GroupStorage groupStorage;

    final testKey = Uint8List.fromList(List.generate(32, (i) => i));
    final testSalt = Uint8List.fromList(List.generate(16, (i) => i + 100));
    const testGroupId = 'deadbeef1234';

    setUp(() {
      fakeStorage = FakeSecureStorage();
      groupStorage = GroupStorage(storage: fakeStorage);
    });

    test('loadGroup returns null when nothing is saved', () async {
      final result = await groupStorage.loadGroup();
      expect(result, isNull);
    });

    test('saveGroup and loadGroup round-trip correctly', () async {
      final createdAt = DateTime(2025, 6, 15, 10, 30);
      await groupStorage.saveGroup(
        groupKey: testKey,
        groupId: testGroupId,
        name: 'My Group',
        createdAt: createdAt,
        salt: testSalt,
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNotNull);
      expect(loaded!.groupKey, equals(testKey));
      expect(loaded.groupId, equals(testGroupId));
      expect(loaded.name, equals('My Group'));
      expect(loaded.createdAt, equals(createdAt));
    });

    test('salt round-trips through save/load', () async {
      await groupStorage.saveGroup(
        groupKey: testKey,
        groupId: testGroupId,
        name: 'Salt Test',
        createdAt: DateTime.now(),
        salt: testSalt,
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNotNull);
      expect(loaded!.salt, equals(testSalt));
    });

    test('deleteGroup clears all stored data including salt', () async {
      await groupStorage.saveGroup(
        groupKey: testKey,
        groupId: testGroupId,
        name: 'Group',
        createdAt: DateTime.now(),
        salt: testSalt,
      );

      await groupStorage.deleteGroup();

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });

    test('saveGroup overwrites previous data', () async {
      final oldKey = Uint8List(32);
      final newKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final oldSalt = Uint8List(16);
      final newSalt = Uint8List.fromList(List.generate(16, (i) => i + 50));

      await groupStorage.saveGroup(
        groupKey: oldKey,
        groupId: 'old-id',
        name: 'Old Group',
        createdAt: DateTime(2024, 1, 1),
        salt: oldSalt,
      );

      await groupStorage.saveGroup(
        groupKey: newKey,
        groupId: 'new-id',
        name: 'New Group',
        createdAt: DateTime(2025, 6, 1),
        salt: newSalt,
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded!.groupKey, equals(newKey));
      expect(loaded.groupId, equals('new-id'));
      expect(loaded.name, equals('New Group'));
      expect(loaded.salt, equals(newSalt));
    });

    test('loadGroup returns null if any field is missing (key only)', () async {
      // Only write the key — other required fields are absent
      await fakeStorage.write(
        key: 'fluxon_group_key',
        value: 'aabbccdd',
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });

    test('loadGroup returns null if salt is missing', () async {
      // Write all fields except salt
      await fakeStorage.write(key: 'fluxon_group_key', value: 'aabb');
      await fakeStorage.write(key: 'fluxon_group_id', value: 'gid');
      await fakeStorage.write(key: 'fluxon_group_name', value: 'G');
      await fakeStorage.write(
          key: 'fluxon_group_created_at',
          value: DateTime.now().toIso8601String());
      // fluxon_group_salt deliberately omitted

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });
  });
}
