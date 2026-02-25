import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxon_app/core/identity/group_cipher.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/group_storage.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/identity/user_profile_manager.dart';
import 'package:fluxon_app/core/providers/group_providers.dart';
import 'package:fluxon_app/core/providers/profile_providers.dart';
import 'package:fluxon_app/features/chat/chat_controller.dart';
import 'package:fluxon_app/features/chat/chat_providers.dart';
import 'package:fluxon_app/features/chat/chat_screen.dart';
import 'package:fluxon_app/features/chat/message_model.dart';

// ---------------------------------------------------------------------------
// Minimal fakes
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

class _FakeGroupCipher implements GroupCipher {
  @override Uint8List? encrypt(Uint8List p, Uint8List? k, {Uint8List? additionalData}) => k == null ? null : Uint8List.fromList(p);
  @override Uint8List? decrypt(Uint8List d, Uint8List? k, {Uint8List? additionalData}) => k == null ? null : Uint8List.fromList(d);
  @override Uint8List deriveGroupKey(String p, Uint8List s) => Uint8List(32);
  @override String generateGroupId(String p, Uint8List s) => 'fake-group';
  @override Uint8List generateSalt() => Uint8List(16);
  @override String encodeSalt(Uint8List s) => 'A' * 26;
  @override Uint8List decodeSalt(String c) => Uint8List(16);
  @override void clearCache() {}
}

class _StubChatController extends StateNotifier<ChatState> implements ChatController {
  _StubChatController(ChatState state) : super(state);
  @override Future<void> sendMessage(String text) async {}
  @override Future<void> clearAllMessages() async { state = const ChatState(); }
  @override Future<void> deleteMessage(String id) async {}
  @override Future<void> markMessagesAsRead(List<ChatMessage> msgs) async {}
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

GroupManager _makeGroupManager() => GroupManager(
  cipher: _FakeGroupCipher(),
  groupStorage: GroupStorage(storage: _FakeSecureStorage()),
);

UserProfileManager _makeProfileManager() =>
    UserProfileManager(storage: _FakeSecureStorage());

// ---------------------------------------------------------------------------
// Helper to build the app with optional active group
// ---------------------------------------------------------------------------

Widget _buildApp({
  required ChatState chatState,
  String displayName = 'Tester',
  bool withGroup = false,
}) {
  final groupManager = _makeGroupManager();
  if (withGroup) {
    groupManager.createGroup('mypassword', groupName: 'Test Group');
  }
  final group = withGroup ? groupManager.activeGroup : null;

  return ProviderScope(
    overrides: [
      chatControllerProvider.overrideWith((_) => _StubChatController(chatState)),
      activeGroupProvider.overrideWith((ref) => group),
      groupManagerProvider.overrideWithValue(groupManager),
      displayNameProvider.overrideWith((ref) => displayName),
      userProfileManagerProvider.overrideWithValue(_makeProfileManager()),
    ],
    child: const MaterialApp(home: ChatScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatScreen', () {
    testWidgets('shows No Group in appBar when no active group', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState()));
      await tester.pumpAndSettle();
      expect(find.text('No Group'), findsOneWidget);
    });

    testWidgets('renders no-group CTA when no active group', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState()));
      await tester.pumpAndSettle();
      expect(find.text('Join your group'), findsOneWidget);
      expect(find.text('Create Group'), findsWidgets);
      expect(find.text('Join Group'), findsWidgets);
    });

    testWidgets('more_vert menu button is always present', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState()));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('shows empty-messages state when group active but no messages', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState(), withGroup: true));
      await tester.pumpAndSettle();
      expect(find.text('No messages yet'), findsOneWidget);
      expect(find.text('Say hello to your group!'), findsOneWidget);
    });

    testWidgets('shows message text field and send button when group active', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState(), withGroup: true));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    });

    testWidgets('input bar hint text is visible', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState(), withGroup: true));
      await tester.pumpAndSettle();
      expect(find.text('Message group...'), findsOneWidget);
    });

    testWidgets('shows message bubbles when messages are present', (tester) async {
      final myPeer = PeerId(Uint8List(32));
      final remotePeer = PeerId(Uint8List.fromList(List.generate(32, (i) => i + 1)));
      final messages = [
        ChatMessage(id: 'm1', sender: myPeer, text: 'Hello mesh!', timestamp: DateTime.now(), isLocal: true),
        ChatMessage(id: 'm2', sender: remotePeer, senderName: 'Bob', text: 'Hi there!', timestamp: DateTime.now(), isLocal: false),
      ];
      await tester.pumpWidget(_buildApp(chatState: ChatState(messages: messages), withGroup: true));
      await tester.pumpAndSettle();
      expect(find.text('Hello mesh!'), findsOneWidget);
      expect(find.text('Hi there!'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('shows CircularProgressIndicator when isSending', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState(isSending: true), withGroup: true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsNothing);
    });

    testWidgets('group name appears in appBar when group is active', (tester) async {
      await tester.pumpWidget(_buildApp(chatState: const ChatState(), withGroup: true));
      await tester.pumpAndSettle();
      expect(find.text('Test Group'), findsOneWidget);
    });

    testWidgets('sender display name shown on incoming messages', (tester) async {
      final remotePeer = PeerId(Uint8List.fromList(List.generate(32, (i) => i + 5)));
      final messages = [
        ChatMessage(id: 'x', sender: remotePeer, senderName: 'Alice', text: 'Hey!', timestamp: DateTime.now(), isLocal: false),
      ];
      await tester.pumpWidget(_buildApp(chatState: ChatState(messages: messages), withGroup: true));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
    });
  });
}
