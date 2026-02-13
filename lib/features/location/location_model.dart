import '../../core/identity/peer_id.dart';
import '../../shared/geo_math.dart';

/// A location update from a group member.
class LocationUpdate {
  final PeerId peerId;
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double speed;
  final double bearing;
  final DateTime timestamp;

  LocationUpdate({
    required this.peerId,
    required this.latitude,
    required this.longitude,
    this.accuracy = 0,
    this.altitude = 0,
    this.speed = 0,
    this.bearing = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Distance to another location (Haversine formula), in meters.
  double distanceTo(LocationUpdate other) {
    return GeoMath.haversineDistance(
      lat1: latitude,
      lon1: longitude,
      lat2: other.latitude,
      lon2: other.longitude,
    );
  }
}
