import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:fluxon_app/core/transport/transport_config.dart';
import 'package:fluxon_app/features/emergency/data/mesh_emergency_repository.dart';
import 'package:fluxon_app/features/emergency/emergency_controller.dart';

// ---------------------------------------------------------------------------
// Mock Transport
// ---------------------------------------------------------------------------

class MockTransport implements Transport {
  final StreamController<FluxonPacket> _packetController =
      StreamController<FluxonPacket>.broadcast();
  final List<FluxonPacket> broadcastedPackets = [];

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    broadcastedPackets.add(packet);
  }

  void simulateIncomingPacket(FluxonPacket packet) {
    _packetController.add(packet);
  }

  void dispose() {
    _packetController.close();
  }

  @override
  Stream<List<PeerConnection>> get connectedPeers => const Stream.empty();
  @override
  bool get isRunning => true;
  @override
  Uint8List get myPeerId => Uint8List(32);
  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async => true;
  @override
  Future<void> startServices() async {}
  @override
  Future<void> stopServices() async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

FluxonPacket _buildEmergencyPacket({
  int senderByte = 0xAA,
  int alertType = 0,
  double lat = 37.7749,
  double lon = -122.4194,
  String message = 'Help!',
}) {
  return BinaryProtocol.buildPacket(
    type: MessageType.emergencyAlert,
    sourceId: Uint8List(32)..fillRange(0, 32, senderByte),
    payload: BinaryProtocol.encodeEmergencyPayload(
      alertType: alertType,
      latitude: lat,
      longitude: lon,
      message: message,
    ),
    ttl: FluxonPacket.maxTTL,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MeshEmergencyRepository', () {
    late MockTransport transport;
    late MeshEmergencyRepository repository;
    final myPeerId = _makePeerId(0xCC);

    setUp(() {
      transport = MockTransport();
      repository = MeshEmergencyRepository(
        transport: transport,
        myPeerId: myPeerId,
        config: const TransportConfig(emergencyRebroadcastCount: 2),
      );
    });

    tearDown(() {
      repository.dispose();
      transport.dispose();
    });

    test('onAlertReceived emits decoded alert for incoming emergency packets',
        () async {
      final packet = _buildEmergencyPacket(
        senderByte: 0xBB,
        alertType: EmergencyAlertType.sos.value,
        lat: 40.0,
        lon: -74.0,
        message: 'SOS!',
      );

      final future = repository.onAlertReceived.first;
      transport.simulateIncomingPacket(packet);

      final alert = await future;
      expect(alert.sender, equals(_makePeerId(0xBB)));
      expect(alert.type, equals(EmergencyAlertType.sos));
      expect(alert.latitude, closeTo(40.0, 0.001));
      expect(alert.longitude, closeTo(-74.0, 0.001));
      expect(alert.message, equals('SOS!'));
    });

    test('onAlertReceived ignores non-emergency packets', () async {
      final chatPacket = BinaryProtocol.buildPacket(
        type: MessageType.chat,
        sourceId: Uint8List(32),
        payload: BinaryProtocol.encodeChatPayload('hello'),
      );

      final completer = Completer<EmergencyAlert>();
      final sub = repository.onAlertReceived.listen(completer.complete);

      transport.simulateIncomingPacket(chatPacket);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, isFalse);

      await sub.cancel();
    });

    test('sendAlert broadcasts N times per config', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.medical,
        latitude: 34.0,
        longitude: -118.0,
        message: 'Need help',
      );

      // Config says emergencyRebroadcastCount = 2
      expect(transport.broadcastedPackets, hasLength(2));

      // All packets should be emergency type with max TTL
      for (final pkt in transport.broadcastedPackets) {
        expect(pkt.type, equals(MessageType.emergencyAlert));
        expect(pkt.ttl, equals(FluxonPacket.maxTTL));
      }
    });

    test('sendAlert encodes payload correctly', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.danger,
        latitude: 51.5,
        longitude: -0.12,
        message: 'Danger zone',
      );

      final pkt = transport.broadcastedPackets.first;
      final decoded = BinaryProtocol.decodeEmergencyPayload(pkt.payload);
      expect(decoded, isNotNull);
      expect(decoded!.alertType, equals(EmergencyAlertType.danger.value));
      expect(decoded.latitude, closeTo(51.5, 0.001));
      expect(decoded.longitude, closeTo(-0.12, 0.001));
      expect(decoded.message, equals('Danger zone'));
    });

    test('sendAlert sets sourceId to myPeerId', () async {
      await repository.sendAlert(
        type: EmergencyAlertType.sos,
        latitude: 0,
        longitude: 0,
      );

      final pkt = transport.broadcastedPackets.first;
      expect(PeerId(pkt.sourceId), equals(myPeerId));
    });

    test('multiple incoming alerts arrive in order', () async {
      final alerts = <EmergencyAlert>[];
      final sub = repository.onAlertReceived.listen(alerts.add);

      transport.simulateIncomingPacket(
        _buildEmergencyPacket(senderByte: 0x01, message: 'first'),
      );
      transport.simulateIncomingPacket(
        _buildEmergencyPacket(senderByte: 0x02, message: 'second'),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(alerts, hasLength(2));
      expect(alerts[0].message, equals('first'));
      expect(alerts[1].message, equals('second'));

      await sub.cancel();
    });
  });
}
