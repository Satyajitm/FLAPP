import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/features/emergency/emergency_controller.dart';
import 'package:fluxon_app/features/emergency/emergency_providers.dart';
import 'package:fluxon_app/features/emergency/emergency_screen.dart';
import 'package:fluxon_app/features/location/location_controller.dart';
import 'package:fluxon_app/features/location/location_providers.dart';

// ---------------------------------------------------------------------------
// Stub controllers
// ---------------------------------------------------------------------------

class _StubEmergencyController extends StateNotifier<EmergencyState>
    implements EmergencyController {
  _StubEmergencyController(EmergencyState state) : super(state);

  @override
  Future<void> sendAlert({
    required EmergencyAlertType type,
    required double latitude,
    required double longitude,
    String message = '',
  }) async {}

  @override
  Future<void> retryAlert() async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubLocationController extends StateNotifier<LocationState>
    implements LocationController {
  _StubLocationController() : super(const LocationState());

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Widget _buildApp(EmergencyState emergencyState) {
  return ProviderScope(
    overrides: [
      emergencyControllerProvider
          .overrideWith((_) => _StubEmergencyController(emergencyState)),
      locationControllerProvider
          .overrideWith((_) => _StubLocationController()),
    ],
    child: const MaterialApp(home: EmergencyScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('EmergencyScreen', () {
    testWidgets('renders Emergency in appBar', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState()));
      await tester.pumpAndSettle();
      expect(find.text('Emergency'), findsOneWidget);
    });

    testWidgets('HOLD FOR SOS text is visible initially', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState()));
      await tester.pumpAndSettle();
      expect(find.text('HOLD FOR SOS'), findsOneWidget);
    });

    testWidgets('alert type chips render (Medical, Lost, Danger)', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState()));
      await tester.pumpAndSettle();
      expect(find.text('Medical'), findsOneWidget);
      expect(find.text('Lost'), findsOneWidget);
      expect(find.text('Danger'), findsOneWidget);
    });

    testWidgets('long press SOS button shows confirmation UI', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState()));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('HOLD FOR SOS'));
      await tester.pumpAndSettle();
      expect(find.text('Send SOS Alert?'), findsOneWidget);
      expect(find.text('SEND SOS'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('Cancel button hides confirmation and restores SOS button', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState()));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('HOLD FOR SOS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('HOLD FOR SOS'), findsOneWidget);
      expect(find.text('Send SOS Alert?'), findsNothing);
    });

    testWidgets('shows CircularProgressIndicator when isSending', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState(isSending: true)));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('HOLD FOR SOS'), findsNothing);
    });

    testWidgets('shows Recent Alerts section when alerts are present', (tester) async {
      final peerId = PeerId(Uint8List(32));
      final alert = EmergencyAlert(
        sender: peerId,
        type: EmergencyAlertType.sos,
        latitude: 0,
        longitude: 0,
        isLocal: true,
      );
      await tester.pumpWidget(_buildApp(EmergencyState(alerts: [alert])));
      await tester.pumpAndSettle();
      expect(find.text('Recent Alerts'), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);
      expect(find.text('Sent by you'), findsOneWidget);
    });

    testWidgets('received alert shows From nearby peer subtitle', (tester) async {
      final peerId = PeerId(Uint8List(32));
      final alert = EmergencyAlert(
        sender: peerId,
        type: EmergencyAlertType.sos,
        latitude: 1.0,
        longitude: 2.0,
        isLocal: false,
      );
      await tester.pumpWidget(_buildApp(EmergencyState(alerts: [alert])));
      await tester.pumpAndSettle();
      expect(find.text('From nearby peer'), findsOneWidget);
    });

    testWidgets('no Recent Alerts section when no alerts', (tester) async {
      await tester.pumpWidget(_buildApp(const EmergencyState()));
      await tester.pumpAndSettle();
      expect(find.text('Recent Alerts'), findsNothing);
    });
  });
}
