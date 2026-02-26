import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'packet.dart';
import 'message_types.dart';

final _secureRandom = Random.secure();

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
    // MED-6: Reject malformed UTF-8 to prevent encoding confusion and
    // homoglyph attacks. Return empty payload on invalid bytes.
    final String raw;
    try {
      raw = utf8.decode(payload, allowMalformed: false);
    } catch (_) {
      return const ChatPayload(senderName: '', text: '');
    }
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
  ///
  /// PROTO-L1: Validates coordinate ranges and rejects NaN / Infinity values
  /// that could crash flutter_map rendering or disable the haversine throttle.
  static LocationPayload? decodeLocationPayload(Uint8List data) {
    if (data.length < 32) return null;
    final buffer = ByteData.sublistView(data);
    final latitude = buffer.getFloat64(0);
    final longitude = buffer.getFloat64(8);
    final accuracy = buffer.getFloat32(16);
    final altitude = buffer.getFloat32(20);
    final speed = buffer.getFloat32(24);
    final bearing = buffer.getFloat32(28);

    if (latitude.isNaN || latitude.isInfinite || latitude < -90 || latitude > 90) {
      return null;
    }
    if (longitude.isNaN || longitude.isInfinite || longitude < -180 || longitude > 180) {
      return null;
    }
    if (accuracy.isNaN || accuracy.isInfinite) return null;
    if (altitude.isNaN || altitude.isInfinite) return null;
    if (speed.isNaN || speed.isInfinite) return null;
    if (bearing.isNaN || bearing.isInfinite) return null;

    return LocationPayload(
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      altitude: altitude,
      speed: speed,
      bearing: bearing,
    );
  }

  /// Encode an emergency alert payload.
  ///
  /// Format: [alertType:1][latitude:8][longitude:8][messageLen:2][message:N]
  /// Maximum message bytes in an emergency payload: 512 (max payload) − 19 (fixed header).
  static const _maxEmergencyMessageBytes = 493;

  static Uint8List encodeEmergencyPayload({
    required int alertType,
    required double latitude,
    required double longitude,
    String message = '',
  }) {
    // MEDIUM: Truncate at encode time to guarantee the total payload never
    // exceeds the 512-byte packet cap, preventing oversized-packet errors.
    final rawBytes = utf8.encode(message);
    final msgBytes = rawBytes.length > _maxEmergencyMessageBytes
        ? rawBytes.sublist(0, _maxEmergencyMessageBytes)
        : rawBytes;
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
    // PROTO-L1: Reject NaN / Infinity and out-of-range coordinates.
    if (latitude.isNaN || latitude.isInfinite || latitude < -90 || latitude > 90) {
      return null;
    }
    if (longitude.isNaN || longitude.isInfinite || longitude < -180 || longitude > 180) {
      return null;
    }
    final msgLen = buffer.getUint16(17);
    if (data.length < 19 + msgLen) return null;
    // INFO-N1: Use allowMalformed: false to reject malformed UTF-8 sequences
    // that could enable homoglyph or encoding-confusion attacks in emergency messages.
    final String message;
    try {
      message = utf8.decode(data.sublist(19, 19 + msgLen), allowMalformed: false);
    } on FormatException {
      return null; // Reject packets with malformed UTF-8 in the message field.
    }
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
    // M12: Cap neighbors at 10 to match the decode-side guard in
    // decodeDiscoveryPayload, preventing oversized payloads.
    final capped = neighbors.sublist(0, neighbors.length.clamp(0, 10));
    final buffer = Uint8List(1 + capped.length * 32);
    buffer[0] = capped.length;
    for (var i = 0; i < capped.length; i++) {
      buffer.setRange(1 + i * 32, 1 + (i + 1) * 32, capped[i]);
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

  /// Sentinel byte that identifies a batch receipt payload.
  static const _batchReceiptSentinel = 0xFF;

  /// Maximum receipts per batch, constrained by the 512-byte packet payload cap.
  ///
  /// Budget: 512 (max payload) − 24 (group-cipher overhead: 8-byte nonce +
  /// 16-byte AEAD tag) − 2 (batch header) = 486 bytes for receipt entries.
  /// Each entry is 41 bytes → floor(486 / 41) = 11.
  static const maxBatchReceiptCount = 11;

  /// Encode multiple receipts into a single payload.
  ///
  /// Format: `[0xFF:1][count:1][receiptType:1][timestamp:8][senderId:32]...`
  ///
  /// At most [maxBatchReceiptCount] receipts are encoded; excess entries are
  /// silently dropped (they will be sent in the next flush cycle).
  static Uint8List encodeBatchReceiptPayload(List<ReceiptPayload> receipts) {
    final count = receipts.length.clamp(0, maxBatchReceiptCount);
    final buffer = ByteData(2 + count * 41);
    buffer.setUint8(0, _batchReceiptSentinel);
    buffer.setUint8(1, count); // safe: count is clamped to 0..maxBatchReceiptCount (11)
    final bytes = buffer.buffer.asUint8List();
    for (var i = 0; i < count; i++) {
      final offset = 2 + i * 41;
      bytes[offset] = receipts[i].receiptType;
      ByteData.sublistView(bytes, offset + 1, offset + 9)
          .setInt64(0, receipts[i].originalTimestamp);
      bytes.setRange(offset + 9, offset + 41, receipts[i].originalSenderId);
    }
    return bytes;
  }

  /// Decode a batch receipt payload. Returns null if the data is not a valid batch.
  static List<ReceiptPayload>? decodeBatchReceiptPayload(Uint8List data) {
    if (data.length < 2) return null;
    if (data[0] != _batchReceiptSentinel) return null;
    final count = data[1];
    if (data.length < 2 + count * 41) return null;
    final result = <ReceiptPayload>[];
    for (var i = 0; i < count; i++) {
      final offset = 2 + i * 41;
      final receiptType = data[offset];
      final timestamp =
          ByteData.sublistView(data, offset + 1, offset + 9).getInt64(0);
      final senderId = Uint8List.fromList(data.sublist(offset + 9, offset + 41));
      result.add(ReceiptPayload(
        receiptType: receiptType,
        originalTimestamp: timestamp,
        originalSenderId: senderId,
      ));
    }
    return result;
  }

  /// Build a complete FluxonPacket from components.
  ///
  /// MED-1: When [flags] is not explicitly provided, a random 8-bit nonce is
  /// generated and stored in [flags]. This ensures packets of the same type
  /// from the same source within the same millisecond get distinct [packetId]s,
  /// preventing legitimate rapid-fire packets from being deduped as one.
  static FluxonPacket buildPacket({
    required MessageType type,
    required Uint8List sourceId,
    Uint8List? destId,
    required Uint8List payload,
    int ttl = FluxonPacket.maxTTL,
    int? flags,
  }) {
    // PROTO-M2: Guard oversized payloads before constructing the packet.
    if (payload.length > FluxonPacket.maxPayloadSize) {
      throw ArgumentError(
          'Payload too large: ${payload.length} > ${FluxonPacket.maxPayloadSize}');
    }
    return FluxonPacket(
      type: type,
      ttl: ttl,
      flags: flags ?? _secureRandom.nextInt(256),
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
