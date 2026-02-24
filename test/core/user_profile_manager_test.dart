import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxon_app/core/identity/user_profile_manager.dart';

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
  }) async => _store[key];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeSecureStorage storage;
  late UserProfileManager manager;

  setUp(() {
    storage = FakeSecureStorage();
    manager = UserProfileManager(storage: storage);
  });

  group('UserProfileManager', () {
    test('displayName is empty on creation', () {
      expect(manager.displayName, isEmpty);
      expect(manager.hasName, isFalse);
    });

    test('initialize loads empty when nothing stored', () async {
      await manager.initialize();
      expect(manager.displayName, isEmpty);
      expect(manager.hasName, isFalse);
    });

    test('initialize loads persisted name', () async {
      await manager.setName('Alice');
      final manager2 = UserProfileManager(storage: storage);
      await manager2.initialize();
      expect(manager2.displayName, equals('Alice'));
      expect(manager2.hasName, isTrue);
    });

    test('setName trims whitespace', () async {
      await manager.setName('  Bob  ');
      expect(manager.displayName, equals('Bob'));
    });

    test('setName enforces 32-character limit', () async {
      await manager.setName('A' * 50);
      expect(manager.displayName.length, 32);
    });

    test('setName with empty string clears the name', () async {
      await manager.setName('Charlie');
      await manager.setName('');
      expect(manager.displayName, isEmpty);
      expect(manager.hasName, isFalse);
    });

    test('setName with whitespace-only string clears the name', () async {
      await manager.setName('Dave');
      await manager.setName('   ');
      expect(manager.displayName, isEmpty);
      expect(manager.hasName, isFalse);
    });

    test('hasName is true after valid setName', () async {
      await manager.setName('Eve');
      expect(manager.hasName, isTrue);
    });

    test('name at exactly 32 chars is stored unchanged', () async {
      final name = 'A' * 32;
      await manager.setName(name);
      expect(manager.displayName, equals(name));
    });

    test('clearance is persisted — reload shows empty', () async {
      await manager.setName('Frank');
      await manager.setName('');
      final manager2 = UserProfileManager(storage: storage);
      await manager2.initialize();
      expect(manager2.displayName, isEmpty);
    });
  });
}
