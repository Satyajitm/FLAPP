import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/device/device_services.dart';

void main() {
  group('GpsPosition', () {
    test('creates with required fields and defaults', () {
      const pos = GpsPosition(latitude: 37.7749, longitude: -122.4194);
      expect(pos.latitude, equals(37.7749));
      expect(pos.longitude, equals(-122.4194));
      expect(pos.accuracy, equals(0));
      expect(pos.altitude, equals(0));
      expect(pos.speed, equals(0));
      expect(pos.heading, equals(0));
    });

    test('creates with all fields', () {
      const pos = GpsPosition(
        latitude: 34.0522,
        longitude: -118.2437,
        accuracy: 10.5,
        altitude: 100.0,
        speed: 5.0,
        heading: 180.0,
      );
      expect(pos.latitude, equals(34.0522));
      expect(pos.longitude, equals(-118.2437));
      expect(pos.accuracy, equals(10.5));
      expect(pos.altitude, equals(100.0));
      expect(pos.speed, equals(5.0));
      expect(pos.heading, equals(180.0));
    });
  });

  group('GpsService interface', () {
    test('mock implementation can be used for testing', () async {
      final mockGps = _MockGpsService(
        const GpsPosition(latitude: 1.0, longitude: 2.0),
      );
      final position = await mockGps.getCurrentPosition();
      expect(position.latitude, equals(1.0));
      expect(position.longitude, equals(2.0));
    });
  });

  group('PermissionService interface', () {
    test('mock implementation can grant permission', () async {
      final mockPerm = _MockPermissionService(true);
      expect(await mockPerm.ensureLocationPermission(), isTrue);
    });

    test('mock implementation can deny permission', () async {
      final mockPerm = _MockPermissionService(false);
      expect(await mockPerm.ensureLocationPermission(), isFalse);
    });
  });
}

// --- Test doubles ---

class _MockGpsService implements GpsService {
  final GpsPosition _position;
  _MockGpsService(this._position);

  @override
  Future<GpsPosition> getCurrentPosition() async => _position;
}

class _MockPermissionService implements PermissionService {
  final bool _granted;
  _MockPermissionService(this._granted);

  @override
  Future<bool> ensureLocationPermission() async => _granted;
}
