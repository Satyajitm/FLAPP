import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxon_app/core/identity/group_cipher.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/group_storage.dart';
import 'package:fluxon_app/core/providers/group_providers.dart';
import 'package:fluxon_app/features/group/create_group_screen.dart';
import 'package:fluxon_app/features/group/join_group_screen.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class FakeGroupCipher implements GroupCipher {
  @override
  Uint8List? encrypt(Uint8List plaintext, Uint8List? groupKey) {
    if (groupKey == null) return null;
    final result = Uint8List(plaintext.length);
    for (var i = 0; i < plaintext.length; i++) {
      result[i] = plaintext[i] ^ groupKey[i % groupKey.length];
    }
    return result;
  }

  @override
  Uint8List? decrypt(Uint8List data, Uint8List? groupKey) =>
      encrypt(data, groupKey);

  @override
  Uint8List deriveGroupKey(String passphrase, Uint8List salt) {
    final key = Uint8List(32);
    final bytes = passphrase.codeUnits;
    for (var i = 0; i < 32; i++) {
      key[i] = bytes[i % bytes.length] ^ (i * 7);
    }
    return key;
  }

  @override
  String generateGroupId(String passphrase) =>
      'fake-group-${passphrase.hashCode.toRadixString(16)}';

  @override
  Uint8List generateSalt() => Uint8List(16); // Fixed salt for deterministic tests
}

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late GroupManager groupManager;

  setUp(() {
    groupManager = GroupManager(
      cipher: FakeGroupCipher(),
      groupStorage: GroupStorage(storage: FakeSecureStorage()),
    );
  });

  group('CreateGroupScreen', () {
    testWidgets('renders all UI elements', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: const MaterialApp(home: CreateGroupScreen()),
        ),
      );

      expect(find.text('Create Group'), findsOneWidget);
      expect(find.text('Create a group'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
    });

    testWidgets('does not create group with empty passphrase', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: const MaterialApp(home: CreateGroupScreen()),
        ),
      );

      // Tap button via its text
      await tester.tap(find.text('Create Group'));
      await tester.pumpAndSettle();

      expect(groupManager.isInGroup, isFalse);
    });

    testWidgets('creates group with passphrase and pops', (tester) async {
      var didPop = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CreateGroupScreen(),
                      ),
                    );
                    didPop = true;
                  },
                  child: const Text('Go'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();

      // Enter passphrase into the second TextField
      final passphraseField = find.byType(TextField).last;
      await tester.enterText(passphraseField, 'my-secret-pass');
      await tester.pumpAndSettle();

      // Tap the create button via its text
      await tester.tap(find.text('Create Group'));
      await tester.pumpAndSettle();

      expect(groupManager.isInGroup, isTrue);
      expect(didPop, isTrue);
    });

    testWidgets('creates group with custom name', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CreateGroupScreen(),
                      ),
                    );
                  },
                  child: const Text('Go'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();

      final nameField = find.byType(TextField).first;
      final passphraseField = find.byType(TextField).last;
      await tester.enterText(nameField, 'Trekking Team');
      await tester.enterText(passphraseField, 'secret123');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create Group'));
      await tester.pumpAndSettle();

      expect(groupManager.activeGroup!.name, equals('Trekking Team'));
    });
  });

  group('JoinGroupScreen', () {
    testWidgets('renders all UI elements', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: const MaterialApp(home: JoinGroupScreen()),
        ),
      );

      expect(find.text('Join Group'), findsOneWidget);
      expect(find.text('Join a group'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('does not join with empty passphrase', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: const MaterialApp(home: JoinGroupScreen()),
        ),
      );

      await tester.tap(find.text('Join Group'));
      await tester.pumpAndSettle();

      expect(groupManager.isInGroup, isFalse);
    });

    testWidgets('joins group with passphrase and pops', (tester) async {
      var didPop = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const JoinGroupScreen(),
                      ),
                    );
                    didPop = true;
                  },
                  child: const Text('Go'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'shared-secret');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Join Group'));
      await tester.pumpAndSettle();

      expect(groupManager.isInGroup, isTrue);
      expect(didPop, isTrue);
    });

    testWidgets('joining same passphrase produces same group key', (tester) async {
      final creator = GroupManager(
        cipher: FakeGroupCipher(),
        groupStorage: GroupStorage(storage: FakeSecureStorage()),
      );
      creator.createGroup('shared-pass', groupName: 'Team');
      final createdKey = Uint8List.fromList(creator.activeGroup!.key);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupManagerProvider.overrideWithValue(groupManager),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const JoinGroupScreen(),
                      ),
                    );
                  },
                  child: const Text('Go'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'shared-pass');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Join Group'));
      await tester.pumpAndSettle();

      expect(groupManager.activeGroup!.key, equals(createdKey));
    });
  });
}
