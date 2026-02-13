import 'dart:async';
import 'dart:typed_data';
import '../protocol/packet.dart';

/// Peer connection info exposed by the transport layer.
class PeerConnection {
  final Uint8List peerId;
  final int rssi;
  final DateTime connectedAt;

  PeerConnection({
    required this.peerId,
    this.rssi = 0,
    DateTime? connectedAt,
  }) : connectedAt = connectedAt ?? DateTime.now();

  String get peerIdHex =>
      peerId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Abstract transport interface.
///
/// BLE implements this today; Fluxo hardware device implements it later.
/// All mesh logic depends only on this interface, never on BLE directly.
abstract class Transport {
  /// Start scanning, advertising, and accepting connections.
  Future<void> startServices();

  /// Stop all transport services.
  Future<void> stopServices();

  /// Send a packet to a specific connected peer.
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId);

  /// Broadcast a packet to all connected peers.
  Future<void> broadcastPacket(FluxonPacket packet);

  /// Stream of received packets from any connected peer.
  Stream<FluxonPacket> get onPacketReceived;

  /// Stream of currently connected peers (emits full list on each change).
  Stream<List<PeerConnection>> get connectedPeers;

  /// This device's peer ID (32-byte public key).
  Uint8List get myPeerId;

  /// Whether the transport is currently active.
  bool get isRunning;
}
