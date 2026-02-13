import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/shared/geo_math.dart';

void main() {
  group('GeoMath', () {
    test('haversineDistance between SF and LA is ~559 km', () {
      final distance = GeoMath.haversineDistance(
        lat1: 37.7749,
        lon1: -122.4194,
        lat2: 34.0522,
        lon2: -118.2437,
      );
      // SF to LA is approximately 559 km
      expect(distance, greaterThan(500000));
      expect(distance, lessThan(700000));
    });

    test('haversineDistance between same point is zero', () {
      final distance = GeoMath.haversineDistance(
        lat1: 37.7749,
        lon1: -122.4194,
        lat2: 37.7749,
        lon2: -122.4194,
      );
      expect(distance, closeTo(0, 0.001));
    });

    test('haversineDistance is symmetric', () {
      final d1 = GeoMath.haversineDistance(
        lat1: 37.7749,
        lon1: -122.4194,
        lat2: 34.0522,
        lon2: -118.2437,
      );
      final d2 = GeoMath.haversineDistance(
        lat1: 34.0522,
        lon1: -118.2437,
        lat2: 37.7749,
        lon2: -122.4194,
      );
      expect(d1, closeTo(d2, 0.001));
    });

    test('haversineDistance between NYC and London is ~5570 km', () {
      final distance = GeoMath.haversineDistance(
        lat1: 40.7128,
        lon1: -74.0060,
        lat2: 51.5074,
        lon2: -0.1278,
      );
      // NYC to London is approximately 5570 km
      expect(distance, greaterThan(5400000));
      expect(distance, lessThan(5700000));
    });

    test('haversineDistance across equator', () {
      final distance = GeoMath.haversineDistance(
        lat1: 1.0,
        lon1: 0.0,
        lat2: -1.0,
        lon2: 0.0,
      );
      // 2 degrees of latitude at the equator ≈ 222 km
      expect(distance, greaterThan(200000));
      expect(distance, lessThan(250000));
    });

    test('haversineDistance across date line', () {
      final distance = GeoMath.haversineDistance(
        lat1: 0.0,
        lon1: 179.0,
        lat2: 0.0,
        lon2: -179.0,
      );
      // 2 degrees of longitude at the equator ≈ 222 km
      expect(distance, greaterThan(200000));
      expect(distance, lessThan(250000));
    });

    test('earthRadiusMeters constant is correct', () {
      expect(GeoMath.earthRadiusMeters, equals(6371000.0));
    });
  });
}
