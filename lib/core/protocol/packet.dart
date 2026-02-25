import 'dart:typed_data';
import '../../shared/hex_utils.dart';
import 'message_types.dart';

/// Binary packet structure for the Fluxon mesh protocol.
///
/// Ported from BitchatPacket with Fluxonlink additions (locationUpdate,
/// emergencyAlert message types).
///
/// All fields are final for value-semantics and LSP compliance.
///
/// Wire format (big-endian):
/// ```
/// [version:1][type:1][ttl:1][flags:1][timestamp:8][sourceId:32][destId:32][payloadLen:2][payload:N][signature:64]
/// ```
class FluxonPacket {
  static const int version = 1;
  static const int headerSize = 78; // 1+1+1+1+8+32+32+2
  static const int signatureSize = 64;
  static const int maxTTL = 7;
  static const int maxPayloadSize = 512;

  final MessageType type;
  final int ttl;
  final int flags;
  final int timestamp; // Unix milliseconds
  final Uint8List sourceId; // 32-byte peer ID
  final Uint8List destId; // 32-byte peer ID (all zeros = broadcast)
  final Uint8List payload;
  final Uint8List? signature; // 64-byte Ed25519 signature

  /// Cached packet ID (computed once, never changes).
  late final String packetId = _computePacketId();

  FluxonPacket({
    required this.type,
    required this.ttl,
    this.flags = 0,
    required this.timestamp,
    required this.sourceId,
    required this.destId,
    required this.payload,
    this.signature,
  });

  /// Whether this packet is a broadcast (destId is all zeros).
  bool get isBroadcast => destId.every((b) => b == 0);

  /// Compute the unique packet identifier for deduplication.
  ///
  /// Called once during construction via the [packetId] late final field.
  ///
  /// MED-1: Include [flags] in the ID so that two packets of the same type
  /// from the same source within the same millisecond get distinct IDs
  /// (flags carries a per-packet random nonce set by [BinaryProtocol.buildPacket]).
  String _computePacketId() {
    return '${HexUtils.encode(sourceId)}:$timestamp:${type.value}:$flags';
  }

  /// Create a copy with a signature attached.
  FluxonPacket withSignature(Uint8List sig) {
    return FluxonPacket(
      type: type,
      ttl: ttl,
      flags: flags,
      timestamp: timestamp,
      sourceId: Uint8List.fromList(sourceId),
      destId: Uint8List.fromList(destId),
      payload: Uint8List.fromList(payload),
      signature: Uint8List.fromList(sig),
    );
  }

  /// Encode packet to binary wire format (without signature).
  Uint8List encode() {
    final buffer = ByteData(headerSize + payload.length);
    var offset = 0;

    buffer.setUint8(offset++, version);
    buffer.setUint8(offset++, type.value);
    buffer.setUint8(offset++, ttl);
    buffer.setUint8(offset++, flags);
    buffer.setInt64(offset, timestamp);
    offset += 8;

    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(offset, offset + 32, sourceId);
    offset += 32;
    bytes.setRange(offset, offset + 32, destId);
    offset += 32;

    buffer.setUint16(offset, payload.length);
    offset += 2;

    bytes.setRange(offset, offset + payload.length, payload);

    return bytes;
  }

  /// Encode packet with signature appended.
  Uint8List encodeWithSignature() {
    final encoded = encode();
    if (signature == null) return encoded;

    final full = Uint8List(encoded.length + signatureSize);
    full.setAll(0, encoded);
    full.setAll(encoded.length, signature!);
    return full;
  }

  /// Decode a packet from binary wire format.
  ///
  /// If [hasSignature] is true, the last 64 bytes are treated as signature.
  static FluxonPacket? decode(Uint8List data, {bool hasSignature = true}) {
    final minSize = hasSignature ? headerSize + signatureSize : headerSize;
    if (data.length < minSize) return null;

    final buffer = ByteData.sublistView(data);
    var offset = 0;

    final ver = buffer.getUint8(offset++);
    if (ver != version) return null;

    final typeValue = buffer.getUint8(offset++);
    final type = MessageType.fromValue(typeValue);
    if (type == null) return null;

    final ttl = buffer.getUint8(offset++);
    // Fix: Reject packets with TTL exceeding the protocol maximum.
    if (ttl > maxTTL) return null;
    final flags = buffer.getUint8(offset++);
    final timestamp = buffer.getInt64(offset);
    offset += 8;
    // Fix: Reject packets whose timestamp deviates more than ±5 minutes
    // from local clock to guard against replay and clock-skew attacks.
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = (timestamp - now).abs();
    if (diff > 5 * 60 * 1000) return null;

    final sourceId = Uint8List.sublistView(data, offset, offset + 32);
    offset += 32;
    final destId = Uint8List.sublistView(data, offset, offset + 32);
    offset += 32;

    final payloadLen = buffer.getUint16(offset);
    offset += 2;
    // Fix: Reject packets claiming a payload larger than the protocol
    // maximum before allocating any buffer memory.
    if (payloadLen > maxPayloadSize) return null;

    if (data.length < offset + payloadLen + (hasSignature ? signatureSize : 0)) {
      return null;
    }

    final payload = Uint8List.sublistView(data, offset, offset + payloadLen);
    offset += payloadLen;

    Uint8List? signature;
    if (hasSignature) {
      signature = Uint8List.sublistView(data, offset, offset + signatureSize);
    }

    return FluxonPacket(
      type: type,
      ttl: ttl,
      flags: flags,
      timestamp: timestamp,
      sourceId: sourceId,
      destId: destId,
      payload: payload,
      signature: signature,
    );
  }

  /// Create a copy with decremented TTL for relaying.
  FluxonPacket withDecrementedTTL() {
    return FluxonPacket(
      type: type,
      ttl: ttl > 0 ? ttl - 1 : 0,
      flags: flags,
      timestamp: timestamp,
      sourceId: Uint8List.fromList(sourceId),
      destId: Uint8List.fromList(destId),
      payload: Uint8List.fromList(payload),
      signature: signature != null ? Uint8List.fromList(signature!) : null,
    );
  }
}
