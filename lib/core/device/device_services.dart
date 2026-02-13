import 'package:geolocator/geolocator.dart';

/// GPS position data, decoupled from any plugin type.
class GpsPosition {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double speed;
  final double heading;

  const GpsPosition({
    required this.latitude,
    required this.longitude,
    this.accuracy = 0,
    this.altitude = 0,
    this.speed = 0,
    this.heading = 0,
  });
}

/// Abstract GPS service interface (DIP).
///
/// Repositories depend on this interface rather than on the concrete
/// Geolocator plugin, enabling easy testing and future hardware swaps.
abstract class GpsService {
  Future<GpsPosition> getCurrentPosition();
}

/// Abstract permission service interface (ISP).
///
/// Separates permission logic from location data retrieval.
abstract class PermissionService {
  Future<bool> ensureLocationPermission();
}

/// Concrete [GpsService] backed by the Geolocator plugin.
class GeolocatorGpsService implements GpsService {
  @override
  Future<GpsPosition> getCurrentPosition() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
    return GpsPosition(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      altitude: position.altitude,
      speed: position.speed,
      heading: position.heading,
    );
  }
}

/// Concrete [PermissionService] backed by the Geolocator plugin.
class GeolocatorPermissionService implements PermissionService {
  @override
  Future<bool> ensureLocationPermission() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      final requested = await Geolocator.requestPermission();
      if (requested == LocationPermission.denied ||
          requested == LocationPermission.deniedForever) {
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }
}
