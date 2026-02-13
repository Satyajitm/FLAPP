import 'dart:async';
import 'dart:typed_data';
import '../../../core/device/device_services.dart';
import '../../../core/identity/group_manager.dart';
import '../../../core/identity/peer_id.dart';
import '../../../core/protocol/binary_protocol.dart';
import '../../../core/protocol/message_types.dart';
import '../../../core/protocol/packet.dart';
import '../../../core/transport/transport.dart';
import '../location_model.dart';
import 'location_repository.dart';

/// Mesh-network implementation of [LocationRepository].
///
/// Listens for incoming [FluxonPacket]s of type [MessageType.locationUpdate],
/// decrypts them with the group key (if in a group), decodes them via
/// [BinaryProtocol], and exposes clean [LocationUpdate] objects.
///
/// Depends on [GpsService] and [PermissionService] (DIP) instead of
/// calling Geolocator directly.
class MeshLocationRepository implements LocationRepository {
  final Transport _transport;
  final GroupManager _groupManager;
  final GpsService _gpsService;
  final PermissionService _permissionService;
  final StreamController<LocationUpdate> _locationController =
      StreamController<LocationUpdate>.broadcast();
  StreamSubscription? _packetSub;

  MeshLocationRepository({
    required Transport transport,
    required GroupManager groupManager,
    required GpsService gpsService,
    required PermissionService permissionService,
  })  : _transport = transport,
        _groupManager = groupManager,
        _gpsService = gpsService,
        _permissionService = permissionService {
    _listenForLocationUpdates();
  }

  void _listenForLocationUpdates() {
    _packetSub = _transport.onPacketReceived
        .where((p) => p.type == MessageType.locationUpdate)
        .listen(_handleIncomingPacket);
  }

  void _handleIncomingPacket(FluxonPacket packet) {
    // Decrypt with group key if in a group
    Uint8List payload = packet.payload;
    if (_groupManager.isInGroup) {
      final decrypted = _groupManager.decryptFromGroup(payload);
      if (decrypted == null) return; // Not in our group
      payload = decrypted;
    }

    final location = BinaryProtocol.decodeLocationPayload(payload);
    if (location == null) return;

    final sender = PeerId(packet.sourceId);
    final update = LocationUpdate(
      peerId: sender,
      latitude: location.latitude,
      longitude: location.longitude,
      accuracy: location.accuracy,
      altitude: location.altitude,
      speed: location.speed,
      bearing: location.bearing,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
    );

    _locationController.add(update);
  }

  @override
  Stream<LocationUpdate> get onLocationReceived => _locationController.stream;

  @override
  Future<LocationUpdate> getCurrentLocation(PeerId myPeerId) async {
    final position = await _gpsService.getCurrentPosition();

    return LocationUpdate(
      peerId: myPeerId,
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      altitude: position.altitude,
      speed: position.speed,
      bearing: position.heading,
    );
  }

  @override
  Future<void> broadcastLocation(
      LocationUpdate location, PeerId sender) async {
    // Encode location payload
    var payload = BinaryProtocol.encodeLocationPayload(
      latitude: location.latitude,
      longitude: location.longitude,
      accuracy: location.accuracy,
      altitude: location.altitude,
      speed: location.speed,
      bearing: location.bearing,
    );

    // Encrypt with group key if in a group
    if (_groupManager.isInGroup) {
      final encrypted = _groupManager.encryptForGroup(payload);
      if (encrypted != null) payload = encrypted;
    }

    final packet = BinaryProtocol.buildPacket(
      type: MessageType.locationUpdate,
      sourceId: sender.bytes,
      payload: payload,
    );

    await _transport.broadcastPacket(packet);
  }

  @override
  Future<bool> ensureLocationPermission() async {
    return _permissionService.ensureLocationPermission();
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _locationController.close();
  }
}
