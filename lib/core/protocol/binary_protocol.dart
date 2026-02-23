import 'dart:convert';
import 'dart:typed_data';
import 'packet.dart';
import 'message_types.dart';

/// Decoded chat payload — contains sender display name and message text.
class ChatPayload {
  /// Sender's display name. Empty string if the message was sent by a legacy
  /// client that did not include a name.
  final String senderName;

  /// Message text content.
  final String text;

  const ChatPayload({required this.senderName, required this.text});
}

/// Encodes and decodes high-level message payloads into FluxonPacket payloads.
///
/// Ported from Bitchat's BinaryProtocol with Fluxonlink additions.
class BinaryProtocol {
  /// Encode a chat message payload.
  ///
  /// When [senderName] is non-empty the payload is serialised as a compact
  /// JSON object: `{"n":"Alice","t":"Hello"}`. Legacy clients (no name) use
  /// plain UTF-8 text so the format is backward-compatible.
  static Uint8List encodeChatPayload(String text, {String senderName = ''}) {
    if (senderName.isEmpty) return Uint8List.fromList(utf8.encode(text));
    final map = {'n': senderName, 't': text};
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  /// Decode a chat message payload.
  ///
  /// Detects the new JSON format (`{"n":`) and returns a [ChatPayload] with
  /// both the sender name and text. Legacy plain-text payloads return an
  /// empty [senderName].
  static ChatPayload decodeChatPayload(Uint8List payload) {
    final raw = utf8.decode(payload, allowMalformed: true);
    // Fix: Use strict key-presence checks instead of a string prefix match
    // to prevent JSON injection via crafted payload content.
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded.containsKey('n') &&
          decoded['n'] is String &&
          decoded.containsKey('t') &&
          decoded['t'] is String) {
        return ChatPayload(
          senderName: decoded['n'] as String,
          text: decoded['t'] as String,
        );
      }
    } catch (_) {
      // Not JSON — fall through to plain-text handling below.
    }
    return ChatPayload(senderName: '', text: raw);
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

  /// Encode a discovery / topology announce payload.
  ///
  /// Format: [neighborCount:1][neighbor1:32][neighbor2:32]...
  /// The sender's peerId is already in the packet header (sourceId),
  /// so only the neighbor list is encoded in the payload.
  static Uint8List encodeDiscoveryPayload({
    required List<Uint8List> neighbors,
  }) {
    final buffer = Uint8List(1 + neighbors.length * 32);
    buffer[0] = neighbors.length;
    for (var i = 0; i < neighbors.length; i++) {
      buffer.setRange(1 + i * 32, 1 + (i + 1) * 32, neighbors[i]);
    }
    return buffer;
  }

  /// Decode a discovery / topology announce payload.
  static DiscoveryPayload? decodeDiscoveryPayload(Uint8List data) {
    if (data.isEmpty) return null;
    final neighborCount = data[0];
    // Fix: Reject unrealistic neighbor counts to prevent oversized allocations.
    if (neighborCount > 10) return null;
    if (data.length < 1 + neighborCount * 32) return null;
    final neighbors = <Uint8List>[];
    for (var i = 0; i < neighborCount; i++) {
      neighbors.add(
        Uint8List.fromList(data.sublist(1 + i * 32, 1 + (i + 1) * 32)),
      );
    }
    return DiscoveryPayload(neighbors: neighbors);
  }

  /// Encode a receipt (ack) payload.
  ///
  /// Format: [receiptType:1][originalTimestamp:8][originalSenderId:32]
  static Uint8List encodeReceiptPayload({
    required int receiptType,
    required int originalTimestamp,
    required Uint8List originalSenderId,
  }) {
    final buffer = ByteData(41);
    buffer.setUint8(0, receiptType);
    buffer.setInt64(1, originalTimestamp);
    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(9, 41, originalSenderId);
    return bytes;
  }

  /// Decode a receipt (ack) payload.
  static ReceiptPayload? decodeReceiptPayload(Uint8List data) {
    if (data.length < 41) return null;
    final buffer = ByteData.sublistView(data);
    final receiptType = buffer.getUint8(0);
    final originalTimestamp = buffer.getInt64(1);
    final originalSenderId = Uint8List.fromList(data.sublist(9, 41));
    return ReceiptPayload(
      receiptType: receiptType,
      originalTimestamp: originalTimestamp,
      originalSenderId: originalSenderId,
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

/// Decoded discovery / topology announce payload.
class DiscoveryPayload {
  final List<Uint8List> neighbors;

  const DiscoveryPayload({required this.neighbors});
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

/// Receipt type flag values for delivery/read receipts.
class ReceiptType {
  static const int delivered = 0x01;
  static const int read = 0x02;
}

/// Decoded receipt (ack) payload.
class ReceiptPayload {
  final int receiptType;
  final int originalTimestamp;
  final Uint8List originalSenderId;

  const ReceiptPayload({
    required this.receiptType,
    required this.originalTimestamp,
    required this.originalSenderId,
  });
}
