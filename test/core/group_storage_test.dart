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
        passphrase: 'test-passphrase',
        name: 'My Group',
        createdAt: createdAt,
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNotNull);
      expect(loaded!.passphrase, equals('test-passphrase'));
      expect(loaded.name, equals('My Group'));
      expect(loaded.createdAt, equals(createdAt));
    });

    test('deleteGroup clears all stored data', () async {
      await groupStorage.saveGroup(
        passphrase: 'secret',
        name: 'Group',
        createdAt: DateTime.now(),
      );

      await groupStorage.deleteGroup();

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });

    test('saveGroup overwrites previous data', () async {
      await groupStorage.saveGroup(
        passphrase: 'old-pass',
        name: 'Old Group',
        createdAt: DateTime(2024, 1, 1),
      );

      await groupStorage.saveGroup(
        passphrase: 'new-pass',
        name: 'New Group',
        createdAt: DateTime(2025, 6, 1),
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded!.passphrase, equals('new-pass'));
      expect(loaded.name, equals('New Group'));
    });

    test('loadGroup returns null if any field is missing', () async {
      // Only write passphrase, not name or createdAt
      await fakeStorage.write(
        key: 'fluxon_group_passphrase',
        value: 'partial',
      );

      final loaded = await groupStorage.loadGroup();
      expect(loaded, isNull);
    });
  });
}
