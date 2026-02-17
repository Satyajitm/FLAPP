/// All message types supported by the Fluxon protocol.
///
/// Values 0x00–0x08 mirror Bitchat's message types.
/// Values 0x09+ are Fluxonlink additions.
enum MessageType {
  /// Noise XX handshake message
  handshake(0x01),

  /// Encrypted chat message
  chat(0x02),

  /// Mesh topology announcement (link-state)
  topologyAnnounce(0x03),

  /// Gossip sync filter (GCS bloom)
  gossipSync(0x04),

  /// Acknowledgement
  ack(0x05),

  /// Ping / keepalive
  ping(0x06),

  /// Pong response
  pong(0x07),

  /// Peer discovery broadcast
  discovery(0x08),

  /// Direct message encrypted via Noise session (private message)
  noiseEncrypted(0x09),

  /// Location update (Fluxonlink-specific)
  locationUpdate(0x0A),

  /// Group join request
  groupJoin(0x0B),

  /// Group join response
  groupJoinResponse(0x0C),

  /// Group key rotation
  groupKeyRotation(0x0D),

  /// Emergency alert (Fluxonlink-specific)
  emergencyAlert(0x0E);

  const MessageType(this.value);
  final int value;

  static MessageType? fromValue(int value) {
    for (final type in MessageType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}
