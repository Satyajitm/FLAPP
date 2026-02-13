import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/features/emergency/data/emergency_repository.dart';
import 'package:fluxon_app/features/emergency/emergency_controller.dart';

// ---------------------------------------------------------------------------
// Fake EmergencyRepository for testing the Controller in isolation
// ---------------------------------------------------------------------------

class FakeEmergencyRepository implements EmergencyRepository {
  final StreamController<EmergencyAlert> _alertController =
      StreamController<EmergencyAlert>.broadcast();
  final List<_SentAlert> sentAlerts = [];

  @override
  Stream<EmergencyAlert> get onAlertReceived => _alertController.stream;

  @override
  Future<void> sendAlert({
    required EmergencyAlertType type,
    required double latitude,
    required double longitude,
    String message = '',
  }) async {
    sentAlerts.add(_SentAlert(
      type: type,
      latitude: latitude,
      longitude: longitude,
      message: message,
    ));
  }

  void simulateIncomingAlert(EmergencyAlert alert) {
    _alertController.add(alert);
  }

  @override
  void dispose() {
    _alertController.close();
  }
}

class _SentAlert {
  final EmergencyAlertType type;
  final double latitude;
  final double longitude;
  final String message;

  _SentAlert({
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.message,
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('EmergencyController', () {
    late FakeEmergencyRepository repository;
    late EmergencyController controller;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      repository = FakeEmergencyRepository();
      controller = EmergencyController(
        repository: repository,
        myPeerId: myPeerId,
      );
    });

    tearDown(() {
      controller.dispose();
      repository.dispose();
    });

    test('initial state is empty and not sending', () {
      expect(controller.state.alerts, isEmpty);
      expect(controller.state.isSending, isFalse);
    });

    test('incoming alerts from repository are added to state', () async {
      final alert = EmergencyAlert(
        sender: _makePeerId(0xBB),
        type: EmergencyAlertType.sos,
        latitude: 40.0,
        longitude: -74.0,
        message: 'Help!',
      );

      repository.simulateIncomingAlert(alert);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.alerts, hasLength(1));
      expect(controller.state.alerts.first.sender, equals(_makePeerId(0xBB)));
      expect(controller.state.alerts.first.type, equals(EmergencyAlertType.sos));
    });

    test('sendAlert delegates to repository and adds local alert to state',
        () async {
      await controller.sendAlert(
        type: EmergencyAlertType.medical,
        latitude: 34.0,
        longitude: -118.0,
        message: 'Need medic',
      );

      // Repository received the send request
      expect(repository.sentAlerts, hasLength(1));
      expect(repository.sentAlerts.first.type, equals(EmergencyAlertType.medical));
      expect(repository.sentAlerts.first.message, equals('Need medic'));

      // Controller state has the local alert
      expect(controller.state.alerts, hasLength(1));
      expect(controller.state.alerts.first.isLocal, isTrue);
      expect(controller.state.alerts.first.sender, equals(myPeerId));
      expect(controller.state.isSending, isFalse);
    });

    test('sendAlert sets isSending back to false after completion', () async {
      await controller.sendAlert(
        type: EmergencyAlertType.sos,
        latitude: 0,
        longitude: 0,
      );

      expect(controller.state.isSending, isFalse);
    });

    test('multiple alerts accumulate in state', () async {
      final remoteAlert = EmergencyAlert(
        sender: _makePeerId(0x01),
        type: EmergencyAlertType.danger,
        latitude: 10.0,
        longitude: 20.0,
      );

      repository.simulateIncomingAlert(remoteAlert);
      await Future.delayed(const Duration(milliseconds: 20));

      await controller.sendAlert(
        type: EmergencyAlertType.sos,
        latitude: 30.0,
        longitude: 40.0,
      );

      expect(controller.state.alerts, hasLength(2));
      expect(controller.state.alerts[0].isLocal, isFalse);
      expect(controller.state.alerts[1].isLocal, isTrue);
    });
  });
}
