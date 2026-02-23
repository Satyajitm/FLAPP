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
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNotNull);
      expect(loaded!.groupKey, equals(testKey));
      expect(loaded.groupId, equals(testGroupId));
      expect(loaded.name, equals('My Group'));
      expect(loaded.createdAt, equals(createdAt));
    });

    test('deleteGroup clears all stored data', () async {
      await groupStorage.saveGroup(
        groupKey: testKey,
        groupId: testGroupId,
        name: 'Group',
        createdAt: DateTime.now(),
      );

      await groupStorage.deleteGroup();

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });

    test('saveGroup overwrites previous data', () async {
      final oldKey = Uint8List(32);
      final newKey = Uint8List.fromList(List.generate(32, (i) => i + 1));

      await groupStorage.saveGroup(
        groupKey: oldKey,
        groupId: 'old-id',
        name: 'Old Group',
        createdAt: DateTime(2024, 1, 1),
      );

      await groupStorage.saveGroup(
        groupKey: newKey,
        groupId: 'new-id',
        name: 'New Group',
        createdAt: DateTime(2025, 6, 1),
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded!.groupKey, equals(newKey));
      expect(loaded.groupId, equals('new-id'));
      expect(loaded.name, equals('New Group'));
    });

    test('loadGroup returns null if any field is missing', () async {
      // Only write part of the data
      await fakeStorage.write(
        key: 'fluxon_group_key',
        value: 'aabbccdd',
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });
  });
}
