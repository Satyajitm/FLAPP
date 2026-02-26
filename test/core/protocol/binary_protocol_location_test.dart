import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';

// Builds a raw 32-byte location payload with explicit float64 lat/lon values
// so we can inject NaN / Infinity without going through the encode helper.
Uint8List _makeLocationBytes({required double lat, required double lon}) {
  final buf = ByteData(32);
  buf.setFloat64(0, lat);
  buf.setFloat64(8, lon);
  buf.setFloat32(16, 5.0); // accuracy
  buf.setFloat32(20, 100.0); // altitude
  buf.setFloat32(24, 0.0); // speed
  buf.setFloat32(28, 0.0); // bearing
  return buf.buffer.asUint8List();
}

// Builds a raw emergency payload with explicit lat/lon values.
Uint8List _makeEmergencyBytes({required double lat, required double lon}) {
  final msgBytes = 'SOS'.codeUnits;
  final buf = ByteData(19 + msgBytes.length);
  buf.setUint8(0, 1); // alertType
  buf.setFloat64(1, lat);
  buf.setFloat64(9, lon);
  buf.setUint16(17, msgBytes.length);
  final bytes = buf.buffer.asUint8List();
  bytes.setRange(19, 19 + msgBytes.length, msgBytes);
  return bytes;
}

void main() {
  group('decodeLocationPayload — PROTO-L1 coordinate validation', () {
    test('valid coordinates decode successfully', () {
      final bytes = _makeLocationBytes(lat: 37.7749, lon: -122.4194);
      final result = BinaryProtocol.decodeLocationPayload(bytes);
      expect(result, isNotNull);
      expect(result!.latitude, closeTo(37.7749, 0.0001));
      expect(result.longitude, closeTo(-122.4194, 0.0001));
    });

    test('NaN latitude returns null', () {
      final bytes = _makeLocationBytes(lat: double.nan, lon: 0.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('positive Infinity latitude returns null', () {
      final bytes = _makeLocationBytes(lat: double.infinity, lon: 0.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('negative Infinity latitude returns null', () {
      final bytes = _makeLocationBytes(lat: double.negativeInfinity, lon: 0.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('NaN longitude returns null', () {
      final bytes = _makeLocationBytes(lat: 0.0, lon: double.nan);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('latitude < -90 returns null', () {
      final bytes = _makeLocationBytes(lat: -91.0, lon: 0.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('latitude > 90 returns null', () {
      final bytes = _makeLocationBytes(lat: 91.0, lon: 0.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('longitude < -180 returns null', () {
      final bytes = _makeLocationBytes(lat: 0.0, lon: -181.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('longitude > 180 returns null', () {
      final bytes = _makeLocationBytes(lat: 0.0, lon: 181.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNull);
    });

    test('boundary lat=90 lon=180 is accepted', () {
      final bytes = _makeLocationBytes(lat: 90.0, lon: 180.0);
      expect(BinaryProtocol.decodeLocationPayload(bytes), isNotNull);
    });

    test('data shorter than 32 bytes returns null', () {
      expect(BinaryProtocol.decodeLocationPayload(Uint8List(10)), isNull);
    });
  });

  group('decodeEmergencyPayload — PROTO-L1 coordinate validation', () {
    test('valid emergency payload decodes successfully', () {
      final bytes = _makeEmergencyBytes(lat: 48.8566, lon: 2.3522);
      final result = BinaryProtocol.decodeEmergencyPayload(bytes);
      expect(result, isNotNull);
      expect(result!.latitude, closeTo(48.8566, 0.0001));
    });

    test('NaN latitude in emergency payload returns null', () {
      final bytes = _makeEmergencyBytes(lat: double.nan, lon: 0.0);
      expect(BinaryProtocol.decodeEmergencyPayload(bytes), isNull);
    });

    test('Infinity longitude in emergency payload returns null', () {
      final bytes = _makeEmergencyBytes(lat: 0.0, lon: double.infinity);
      expect(BinaryProtocol.decodeEmergencyPayload(bytes), isNull);
    });

    test('latitude > 90 in emergency payload returns null', () {
      final bytes = _makeEmergencyBytes(lat: 95.0, lon: 0.0);
      expect(BinaryProtocol.decodeEmergencyPayload(bytes), isNull);
    });

    test('longitude < -180 in emergency payload returns null', () {
      final bytes = _makeEmergencyBytes(lat: 0.0, lon: -200.0);
      expect(BinaryProtocol.decodeEmergencyPayload(bytes), isNull);
    });
  });

  group('buildPacket — PROTO-M2 payload size guard', () {
    test('buildPacket throws ArgumentError for oversized payload', () {
      expect(
        () => BinaryProtocol.buildPacket(
          type: MessageType.chat,
          sourceId: Uint8List(32),
          payload: Uint8List(513),
        ),
        throwsArgumentError,
      );
    });
  });
}
