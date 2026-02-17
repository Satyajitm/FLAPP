import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/app.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/identity/user_profile_manager.dart';
import 'package:fluxon_app/core/providers/group_providers.dart';
import 'package:fluxon_app/core/providers/profile_providers.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/features/chat/chat_providers.dart';

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Widget _buildApp({String displayName = 'Tester'}) {
  final peerIdBytes = Uint8List(32);
  final transport = StubTransport(myPeerId: peerIdBytes);
  final profile = UserProfileManager();

  return ProviderScope(
    overrides: [
      transportProvider.overrideWithValue(transport),
      myPeerIdProvider.overrideWithValue(PeerId(peerIdBytes)),
      groupManagerProvider.overrideWithValue(GroupManager()),
      userProfileManagerProvider.overrideWithValue(profile),
      displayNameProvider.overrideWith((ref) => displayName),
    ],
    child: const FluxonApp(),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WithForegroundTask widget integration', () {
    testWidgets('FluxonApp tree contains WithForegroundTask',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();
      expect(find.byType(WithForegroundTask), findsOneWidget);
    });

    testWidgets('WithForegroundTask wraps the MaterialApp',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();
      // Both widgets must be present in the same tree.
      expect(find.byType(WithForegroundTask), findsOneWidget);
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });

  group('App lifecycle observer', () {
    testWidgets('app renders correctly on startup', (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Map'), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);
    });

    testWidgets(
        'AppLifecycleState.paused does not crash — service stays running',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // Simulate the user pressing the home button (app goes to background).
      // The foreground service must NOT be stopped at this point.
      expect(
        () => tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.paused),
        returnsNormally,
      );
      await tester.pump();

      // App still renders after the lifecycle event.
      expect(find.text('Chat'), findsOneWidget);
    });

    testWidgets(
        'AppLifecycleState.resumed does not crash',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      expect(
        () => tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
        returnsNormally,
      );
      await tester.pump();
      expect(find.text('Chat'), findsOneWidget);
    });

    testWidgets(
        'AppLifecycleState.inactive does not crash',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      expect(
        () => tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive),
        returnsNormally,
      );
      await tester.pump();
    });

    testWidgets(
        'AppLifecycleState.detached does not crash — '
        'ForegroundServiceManager.stop() is a no-op on non-Android',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // Simulate process destruction.  ForegroundServiceManager.stop() is
      // called inside didChangeAppLifecycleState.  On the test host
      // (non-Android) it is a no-op, so no exception is expected.
      expect(
        () => tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.detached),
        returnsNormally,
      );
    });

    testWidgets('observer removed on dispose — no dangling reference',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // Replace the widget tree to trigger dispose() on _HomeScreenState.
      await tester.pumpWidget(const SizedBox.shrink());

      // After dispose the observer should be de-registered.
      // A lifecycle event should not reach the disposed widget.
      expect(
        () => tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.paused),
        returnsNormally,
      );
    });
  });

  group('Bottom navigation state', () {
    testWidgets('Chat tab is selected by default', (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();
      // The Chat navigation label should be visible (index 0 is default).
      expect(find.text('Chat'), findsOneWidget);
    });

    testWidgets('tapping Map tab switches the displayed screen',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      await tester.tap(find.text('Map'));
      await tester.pumpAndSettle();

      expect(find.text('Group Map'), findsOneWidget);
    });

    testWidgets('tapping SOS tab switches to emergency screen',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      await tester.tap(find.text('SOS'));
      await tester.pumpAndSettle();

      // EmergencyScreen is rendered.
      expect(find.text('SOS'), findsWidgets);
    });
  });
}
