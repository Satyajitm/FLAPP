import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxon_app/core/identity/user_profile_manager.dart';
import 'package:fluxon_app/core/providers/profile_providers.dart';
import 'package:fluxon_app/features/onboarding/onboarding_screen.dart';

// ---------------------------------------------------------------------------
// Fake storage (reused from other test files)
// ---------------------------------------------------------------------------

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<void> write({required String key, required String? value, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async {
    if (value != null) _store[key] = value; else _store.remove(key);
  }
  @override
  Future<String?> read({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _store[key];
  @override
  Future<void> delete({required String key, IOSOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, MacOsOptions? mOptions, WindowsOptions? wOptions}) async => _store.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Widget _buildApp(UserProfileManager manager) {
  return ProviderScope(
    overrides: [
      userProfileManagerProvider.overrideWithValue(manager),
      displayNameProvider.overrideWith((ref) => ''),
    ],
    child: const MaterialApp(home: OnboardingScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late UserProfileManager manager;

  setUp(() {
    manager = UserProfileManager(storage: _FakeSecureStorage());
  });

  group('OnboardingScreen', () {
    testWidgets('renders welcome text', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to FluxonApp'), findsOneWidget);
    });

    testWidgets('renders name TextField', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets("renders Let's go button", (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      expect(find.text("Let's go"), findsOneWidget);
    });

    testWidgets('renders person_outline icon', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('empty name does not save', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Let's go"));
      await tester.pumpAndSettle();
      expect(manager.displayName, isEmpty);
    });

    testWidgets('whitespace-only name does not save', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      await tester.tap(find.text("Let's go"));
      await tester.pumpAndSettle();
      expect(manager.displayName, isEmpty);
    });

    testWidgets('valid name is saved after tapping button', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alice');
      await tester.pump();
      await tester.tap(find.text("Let's go"));
      await tester.pump(); // one frame to process the async save
      expect(manager.displayName, equals('Alice'));
    });

    testWidgets('submitting with keyboard done action saves name', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(manager.displayName, equals('Bob'));
    });

    testWidgets('name is trimmed of whitespace before saving', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' Charlie ');
      await tester.pump();
      await tester.tap(find.text("Let's go"));
      await tester.pump();
      expect(manager.displayName, equals('Charlie'));
    });

    testWidgets('saved name length does not exceed 32 characters', (tester) async {
      await tester.pumpWidget(_buildApp(manager));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'A' * 40);
      await tester.pump();
      await tester.tap(find.text("Let's go"));
      await tester.pump();
      expect(manager.displayName.length, lessThanOrEqualTo(32));
    });
  });
}
