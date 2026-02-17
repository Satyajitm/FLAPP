import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/device/device_services.dart';
import 'package:fluxon_app/core/identity/group_manager.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/providers/group_providers.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/features/chat/chat_providers.dart';
import 'package:fluxon_app/features/location/location_providers.dart';
import 'package:fluxon_app/features/location/location_screen.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class _FakeGpsService implements GpsService {
  @override
  Future<GpsPosition> getCurrentPosition() async {
    return const GpsPosition(latitude: 37.7749, longitude: -122.4194);
  }
}

class _FakePermissionService implements PermissionService {
  final bool _grant;
  const _FakePermissionService({bool grant = true}) : _grant = grant;

  @override
  Future<bool> ensureLocationPermission() async => _grant;
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Widget _buildLocationScreen({
  bool permissionGranted = true,
}) {
  final peerIdBytes = Uint8List(32);
  final transport = StubTransport(myPeerId: peerIdBytes);

  return ProviderScope(
    overrides: [
      transportProvider.overrideWithValue(transport),
      myPeerIdProvider.overrideWithValue(PeerId(peerIdBytes)),
      groupManagerProvider.overrideWithValue(GroupManager()),
      gpsServiceProvider.overrideWithValue(_FakeGpsService()),
      permissionServiceProvider.overrideWithValue(
        _FakePermissionService(grant: permissionGranted),
      ),
    ],
    child: const MaterialApp(home: LocationScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('LocationScreen rendering', () {
    testWidgets('renders without crashing', (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();
      expect(find.byType(LocationScreen), findsOneWidget);
    });

    testWidgets('shows "Group Map" app-bar title', (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();
      expect(find.text('Group Map'), findsOneWidget);
    });

    testWidgets('shows my_location FAB', (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byIcon(Icons.my_location), findsOneWidget);
    });

    testWidgets('contains a FlutterMap widget', (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget);
    });

    testWidgets('contains a TileLayer', (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();
      expect(find.byType(TileLayer), findsOneWidget);
    });
  });

  group('LocationScreen broadcast toggle', () {
    testWidgets('shows location_off icon when not broadcasting',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();
      expect(find.byIcon(Icons.location_off), findsOneWidget);
      expect(find.byIcon(Icons.location_on), findsNothing);
    });

    testWidgets('tapping toggle switches icon to location_on',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();

      await tester.tap(find.byIcon(Icons.location_off));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.location_on), findsOneWidget);
      expect(find.byIcon(Icons.location_off), findsNothing);
    });

    testWidgets('tapping toggle again stops broadcasting and restores icon',
        (WidgetTester tester) async {
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump();

      // Start broadcasting
      await tester.tap(find.byIcon(Icons.location_off));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.location_on), findsOneWidget);

      // Stop broadcasting
      await tester.tap(find.byIcon(Icons.location_on));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.location_off), findsOneWidget);
    });

    testWidgets(
        'broadcast toggle is a no-op when permission denied — icon stays off',
        (WidgetTester tester) async {
      await tester
          .pumpWidget(_buildLocationScreen(permissionGranted: false));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.location_off));
      await tester.pumpAndSettle();

      // Permission denied → controller.startBroadcasting() does nothing
      expect(find.byIcon(Icons.location_off), findsOneWidget);
    });
  });

  group('LocationScreen tile cache init', () {
    testWidgets(
        '_tileProvider starts null — TileLayer still renders with default provider',
        (WidgetTester tester) async {
      // The cache directory doesn't exist in the test environment, so
      // _initTileCache will catch the exception and leave _tileProvider null.
      // flutter_map falls back to NetworkTileProvider in that case.
      await tester.pumpWidget(_buildLocationScreen());
      await tester.pump(); // first frame — _tileProvider is null

      // TileLayer must be present regardless of cache init outcome.
      expect(find.byType(TileLayer), findsOneWidget);
    });

    testWidgets('no exception thrown during tile cache initialisation',
        (WidgetTester tester) async {
      await expectLater(
        () async {
          await tester.pumpWidget(_buildLocationScreen());
          await tester.pump();
          // Allow any async tile-cache init to complete (or silently fail).
          await tester.pump(const Duration(milliseconds: 100));
        },
        returnsNormally,
      );
    });
  });
}
