import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/features/location/location_model.dart';

void main() {
  group('LocationModel', () {
    test('creates with required fields', () {
      final loc = LocationUpdate(
        peerId: PeerId(Uint8List(32)),
        latitude: 37.7749,
        longitude: -122.4194,
      );

      expect(loc.latitude, equals(37.7749));
      expect(loc.longitude, equals(-122.4194));
      expect(loc.accuracy, equals(0));
    });

    test('distanceTo computes reasonable distance', () {
      final sf = LocationUpdate(
        peerId: PeerId(Uint8List(32)),
        latitude: 37.7749,
        longitude: -122.4194,
      );
      final la = LocationUpdate(
        peerId: PeerId(Uint8List(32)),
        latitude: 34.0522,
        longitude: -118.2437,
      );

      final distance = sf.distanceTo(la);
      // SF to LA is ~559 km
      expect(distance, greaterThan(500000));
      expect(distance, lessThan(700000));
    });

    test('distanceTo self is zero', () {
      final loc = LocationUpdate(
        peerId: PeerId(Uint8List(32)),
        latitude: 37.7749,
        longitude: -122.4194,
      );
      expect(loc.distanceTo(loc), closeTo(0, 1));
    });
  });

  group('LocationPayload encoding', () {
    test('encode and decode round-trip', () {
      final encoded = BinaryProtocol.encodeLocationPayload(
        latitude: 37.7749,
        longitude: -122.4194,
        accuracy: 10.5,
        altitude: 50.0,
        speed: 1.5,
        bearing: 180.0,
      );

      expect(encoded.length, equals(32));

      final decoded = BinaryProtocol.decodeLocationPayload(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.latitude, closeTo(37.7749, 0.0001));
      expect(decoded.longitude, closeTo(-122.4194, 0.0001));
      expect(decoded.accuracy, closeTo(10.5, 0.1));
      expect(decoded.altitude, closeTo(50.0, 0.1));
      expect(decoded.speed, closeTo(1.5, 0.1));
      expect(decoded.bearing, closeTo(180.0, 0.1));
    });

    test('decode rejects short payload', () {
      expect(BinaryProtocol.decodeLocationPayload(Uint8List(10)), isNull);
    });
  });
}
