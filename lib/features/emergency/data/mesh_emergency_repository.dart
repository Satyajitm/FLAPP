import 'dart:async';
import 'dart:typed_data';
import '../../../core/identity/peer_id.dart';
import '../../../core/protocol/binary_protocol.dart';
import '../../../core/protocol/message_types.dart';
import '../../../core/protocol/packet.dart';
import '../../../core/transport/transport.dart';
import '../../../core/transport/transport_config.dart';
import '../emergency_controller.dart';
import 'emergency_repository.dart';

/// Mesh-network implementation of [EmergencyRepository].
///
/// Handles packet encoding/decoding, re-broadcasting, and transport delivery.
class MeshEmergencyRepository implements EmergencyRepository {
  final Transport _transport;
  final PeerId _myPeerId;
  final TransportConfig _config;
  final StreamController<EmergencyAlert> _alertController =
      StreamController<EmergencyAlert>.broadcast();
  StreamSubscription? _packetSub;

  MeshEmergencyRepository({
    required Transport transport,
    required PeerId myPeerId,
    TransportConfig config = TransportConfig.defaultConfig,
  })  : _transport = transport,
        _myPeerId = myPeerId,
        _config = config {
    _listenForAlerts();
  }

  void _listenForAlerts() {
    _packetSub = _transport.onPacketReceived
        .where((p) => p.type == MessageType.emergencyAlert)
        .listen(_handleIncomingAlert);
  }

  void _handleIncomingAlert(FluxonPacket packet) {
    final payload = BinaryProtocol.decodeEmergencyPayload(packet.payload);
    if (payload == null) return;

    final alert = EmergencyAlert(
      sender: PeerId(packet.sourceId),
      type: EmergencyAlertType.values.firstWhere(
        (t) => t.value == payload.alertType,
        orElse: () => EmergencyAlertType.sos,
      ),
      latitude: payload.latitude,
      longitude: payload.longitude,
      message: payload.message,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
    );

    _alertController.add(alert);
  }

  @override
  Stream<EmergencyAlert> get onAlertReceived => _alertController.stream;

  @override
  Future<void> sendAlert({
    required EmergencyAlertType type,
    required double latitude,
    required double longitude,
    String message = '',
  }) async {
    final payload = BinaryProtocol.encodeEmergencyPayload(
      alertType: type.value,
      latitude: latitude,
      longitude: longitude,
      message: message,
    );

    final packet = BinaryProtocol.buildPacket(
      type: MessageType.emergencyAlert,
      sourceId: _myPeerId.bytes,
      payload: payload,
      ttl: FluxonPacket.maxTTL,
    );

    // Broadcast multiple times for reliability
    for (var i = 0; i < _config.emergencyRebroadcastCount; i++) {
      await _transport.broadcastPacket(packet);
      if (i < _config.emergencyRebroadcastCount - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _alertController.close();
  }
}
