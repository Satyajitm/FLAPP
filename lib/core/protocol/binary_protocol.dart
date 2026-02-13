import 'dart:convert';
import 'dart:typed_data';
import 'packet.dart';
import 'message_types.dart';

/// Encodes and decodes high-level message payloads into FluxonPacket payloads.
///
/// Ported from Bitchat's BinaryProtocol with Fluxonlink additions.
class BinaryProtocol {
  /// Encode a chat message payload.
  static Uint8List encodeChatPayload(String text) {
    return Uint8List.fromList(utf8.encode(text));
  }

  /// Decode a chat message payload.
  static String decodeChatPayload(Uint8List payload) {
    return utf8.decode(payload, allowMalformed: true);
  }

  /// Encode a location update payload.
  ///
  /// Format: [latitude:8][longitude:8][accuracy:4][altitude:4][speed:4][bearing:4]
  static Uint8List encodeLocationPayload({
    required double latitude,
    required double longitude,
    double accuracy = 0,
    double altitude = 0,
    double speed = 0,
    double bearing = 0,
  }) {
    final buffer = ByteData(32);
    buffer.setFloat64(0, latitude);
    buffer.setFloat64(8, longitude);
    buffer.setFloat32(16, accuracy);
    buffer.setFloat32(20, altitude);
    buffer.setFloat32(24, speed);
    buffer.setFloat32(28, bearing);
    return buffer.buffer.asUint8List();
  }

  /// Decode a location update payload.
  static LocationPayload? decodeLocationPayload(Uint8List data) {
    if (data.length < 32) return null;
    final buffer = ByteData.sublistView(data);
    return LocationPayload(
      latitude: buffer.getFloat64(0),
      longitude: buffer.getFloat64(8),
      accuracy: buffer.getFloat32(16),
      altitude: buffer.getFloat32(20),
      speed: buffer.getFloat32(24),
      bearing: buffer.getFloat32(28),
    );
  }

  /// Encode an emergency alert payload.
  ///
  /// Format: [alertType:1][latitude:8][longitude:8][messageLen:2][message:N]
  static Uint8List encodeEmergencyPayload({
    required int alertType,
    required double latitude,
    required double longitude,
    String message = '',
  }) {
    final msgBytes = utf8.encode(message);
    final buffer = ByteData(19 + msgBytes.length);
    buffer.setUint8(0, alertType);
    buffer.setFloat64(1, latitude);
    buffer.setFloat64(9, longitude);
    buffer.setUint16(17, msgBytes.length);
    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(19, 19 + msgBytes.length, msgBytes);
    return bytes;
  }

  /// Decode an emergency alert payload.
  static EmergencyPayload? decodeEmergencyPayload(Uint8List data) {
    if (data.length < 19) return null;
    final buffer = ByteData.sublistView(data);
    final alertType = buffer.getUint8(0);
    final latitude = buffer.getFloat64(1);
    final longitude = buffer.getFloat64(9);
    final msgLen = buffer.getUint16(17);
    if (data.length < 19 + msgLen) return null;
    final message = utf8.decode(data.sublist(19, 19 + msgLen), allowMalformed: true);
    return EmergencyPayload(
      alertType: alertType,
      latitude: latitude,
      longitude: longitude,
      message: message,
    );
  }

  /// Build a complete FluxonPacket from components.
  static FluxonPacket buildPacket({
    required MessageType type,
    required Uint8List sourceId,
    Uint8List? destId,
    required Uint8List payload,
    int ttl = FluxonPacket.maxTTL,
    int flags = 0,
  }) {
    return FluxonPacket(
      type: type,
      ttl: ttl,
      flags: flags,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      sourceId: sourceId,
      destId: destId ?? Uint8List(32), // all zeros = broadcast
      payload: payload,
    );
  }
}

/// Decoded location payload.
class LocationPayload {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double speed;
  final double bearing;

  const LocationPayload({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.speed,
    required this.bearing,
  });
}

/// Decoded emergency alert payload.
class EmergencyPayload {
  final int alertType;
  final double latitude;
  final double longitude;
  final String message;

  const EmergencyPayload({
    required this.alertType,
    required this.latitude,
    required this.longitude,
    required this.message,
  });
}
