import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import '../../../core/identity/group_manager.dart';
import '../../../core/identity/peer_id.dart';
import '../../../core/protocol/binary_protocol.dart';
import '../../../core/protocol/message_types.dart';
import '../../../core/protocol/packet.dart';
import '../../../core/transport/transport.dart';
import '../../../core/transport/transport_config.dart';
import '../../../shared/logger.dart';
import '../emergency_controller.dart';
import 'emergency_repository.dart';

/// Mesh-network implementation of [EmergencyRepository].
///
/// Handles packet encoding/decoding, re-broadcasting, and transport delivery.
/// When in a group, payloads are encrypted/decrypted with the group key.
class MeshEmergencyRepository implements EmergencyRepository {
  final Transport _transport;
  final PeerId _myPeerId;
  final TransportConfig _config;
  final GroupManager _groupManager;
  final StreamController<EmergencyAlert> _alertController =
      StreamController<EmergencyAlert>.broadcast();
  StreamSubscription? _packetSub;

  MeshEmergencyRepository({
    required Transport transport,
    required PeerId myPeerId,
    TransportConfig config = TransportConfig.defaultConfig,
    GroupManager? groupManager,
  })  : _transport = transport,
        _myPeerId = myPeerId,
        _config = config,
        _groupManager = groupManager ?? GroupManager() {
    _listenForAlerts();
  }

  void _listenForAlerts() {
    _packetSub = _transport.onPacketReceived
        .where((p) => p.type == MessageType.emergencyAlert)
        .listen(
          _handleIncomingAlert,
          onError: (Object e) => SecureLogger.warning(
            'MeshEmergencyRepository: transport stream error: $e',
          ),
        );
  }

  void _handleIncomingAlert(FluxonPacket packet) {
    // Decrypt with group key if in a group
    Uint8List rawPayload = packet.payload;
    if (_groupManager.isInGroup) {
      final decrypted = _groupManager.decryptFromGroup(rawPayload);
      if (decrypted == null) return; // Not in our group — drop
      rawPayload = decrypted;
    }

    final payload = BinaryProtocol.decodeEmergencyPayload(rawPayload);
    if (payload == null) return;

    final alert = EmergencyAlert(
      sender: PeerId(packet.sourceId),
      type: EmergencyAlertType.fromValue(payload.alertType) ?? EmergencyAlertType.sos,
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
    var payload = BinaryProtocol.encodeEmergencyPayload(
      alertType: type.value,
      latitude: latitude,
      longitude: longitude,
      message: message,
    );

    // Encrypt with group key if in a group
    if (_groupManager.isInGroup) {
      final encrypted = _groupManager.encryptForGroup(payload);
      if (encrypted != null) payload = encrypted;
    }

    // HIGH-5: Generate a distinct packet for each rebroadcast so receiving
    // peers' deduplicators treat each transmission as unique. This provides
    // true N-attempt reliability instead of only 1-attempt with N broadcasts.
    // Random jitter on the delay also reduces traffic-analysis fingerprinting.
    final rng = Random.secure();
    for (var i = 0; i < _config.emergencyRebroadcastCount; i++) {
      final packet = BinaryProtocol.buildPacket(
        type: MessageType.emergencyAlert,
        sourceId: _myPeerId.bytes,
        payload: payload,
        ttl: FluxonPacket.maxTTL,
      );
      await _transport.broadcastPacket(packet);
      if (i < _config.emergencyRebroadcastCount - 1) {
        // Add random jitter (400–600 ms) to reduce timing fingerprint.
        final jitter = 400 + rng.nextInt(201);
        await Future.delayed(Duration(milliseconds: jitter));
      }
    }
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _alertController.close();
  }
}
