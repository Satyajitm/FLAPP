import 'dart:async';
import '../../../core/identity/peer_id.dart';
import '../location_model.dart';

/// Abstract interface for location data operations.
///
/// Decouples the [LocationController] from transport, protocol, encryption,
/// and GPS hardware concerns. Implementations handle packet encoding/decoding,
/// group encryption, and GPS access.
abstract class LocationRepository {
  /// Stream of incoming location updates from other peers, fully decrypted
  /// and decoded.
  Stream<LocationUpdate> get onLocationReceived;

  /// Fetch the current device GPS position and return it as a
  /// [LocationUpdate].
  ///
  /// Throws if GPS is unavailable.
  Future<LocationUpdate> getCurrentLocation(PeerId myPeerId);

  /// Broadcast a location update to all connected peers.
  ///
  /// Handles encoding, optional group encryption, and transport delivery.
  Future<void> broadcastLocation(LocationUpdate location, PeerId sender);

  /// Check and request GPS permissions.
  ///
  /// Returns `true` if permissions are granted.
  Future<bool> ensureLocationPermission();

  /// Release any resources held by this repository.
  void dispose();
}
