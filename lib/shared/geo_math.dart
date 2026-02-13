import 'dart:math' as math;

/// Geographic math utilities extracted from LocationUpdate (SRP).
///
/// Uses dart:math instead of custom Taylor series implementations.
class GeoMath {
  /// Earth radius in meters.
  static const double earthRadiusMeters = 6371000.0;

  /// Haversine distance between two lat/lon points, in meters.
  static double haversineDistance({
    required double lat1,
    required double lon1,
    required double lat2,
    required double lon2,
  }) {
    final lat1Rad = _toRadians(lat1);
    final lat2Rad = _toRadians(lat2);
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1Rad) * math.cos(lat2Rad) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _toRadians(double degrees) => degrees * (math.pi / 180);
}
