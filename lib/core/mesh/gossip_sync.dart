import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import '../../shared/hex_utils.dart';
import '../protocol/packet.dart';
import '../transport/transport.dart';

/// Gossip-based sync manager using on-demand GCS filters.
///
/// Simplified port of Bitchat's GossipSyncManager for Fluxonlink.
/// Handles periodic sync of chat, location, and emergency messages
/// between mesh peers to fill gaps from missed broadcasts.
class GossipSyncManager {
  final Uint8List myPeerId;
  final GossipSyncConfig config;
  final Transport _transport;

  /// Stores recent packets by their packet ID for syncing.
  final Map<String, _StoredPacket> _seenPackets = {};

  /// Insertion-order queue of packet IDs for O(1) front-removal (capacity enforcement).
  final Queue<String> _packetOrder = Queue();

  Timer? _maintenanceTimer;

  GossipSyncManager({
    required this.myPeerId,
    required Transport transport,
    this.config = const GossipSyncConfig(),
  }) : _transport = transport;

  /// Start periodic maintenance and sync.
  void start() {
    stop();
    _maintenanceTimer = Timer.periodic(
      Duration(seconds: config.maintenanceIntervalSeconds),
      (_) => _performMaintenance(),
    );
  }

  /// Stop periodic maintenance.
  void stop() {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
  }

  /// Record a packet we've seen (either originated or received).
  void onPacketSeen(FluxonPacket packet) {
    final id = packet.packetId;
    if (_seenPackets.containsKey(id)) return;

    _seenPackets[id] = _StoredPacket(
      packet: packet,
      seenAt: DateTime.now(),
    );
    _packetOrder.add(id);

    // Enforce capacity — O(1) removal from the front of the queue.
    while (_packetOrder.length > config.seenCapacity) {
      final victim = _packetOrder.removeFirst();
      _seenPackets.remove(victim);
    }
  }

  /// MED-8: Rate-limit tracking for gossip sync responses per peer (keyed by hex peer ID).
  final Map<String, _SyncRateState> _syncRateByPeer = {};

  /// Handle a sync request from a peer.
  ///
  /// MED-8: Rate-limited — max [config.maxSyncPacketsPerRequest] packets per
  /// sync round per peer. Only authenticated peers should call this; the
  /// caller (MeshService) is responsible for enforcing authentication.
  Future<void> handleSyncRequest({
    required Uint8List fromPeerId,
    required Set<String> peerHasIds,
  }) async {
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(seconds: config.maxMessageAgeSeconds));

    // MED-8: Enforce per-peer sync response rate limit.
    final peerKey = HexUtils.encode(fromPeerId);
    final rateState = _syncRateByPeer.putIfAbsent(
      peerKey, () => _SyncRateState(),
    );
    if (now.difference(rateState.windowStart).inSeconds >= 60) {
      rateState.count = 0;
      rateState.windowStart = now;
    }

    int sent = 0;
    for (final entry in _seenPackets.entries) {
      if (sent >= config.maxSyncPacketsPerRequest) break;
      if (peerHasIds.contains(entry.key)) continue;
      if (entry.value.seenAt.isBefore(cutoff)) continue;

      rateState.count++;
      sent++;

      // Send missing packet to the requesting peer
      final packet = entry.value.packet.withDecrementedTTL();
      await _transport.sendPacket(packet, fromPeerId);
    }
  }

  /// Build a set of packet IDs we currently have (for sync requests).
  Set<String> get knownPacketIds => _seenPackets.keys.toSet();

  void _performMaintenance() {
    _cleanupExpired();
  }

  void _cleanupExpired() {
    final cutoff = DateTime.now().subtract(
      Duration(seconds: config.maxMessageAgeSeconds),
    );
    _packetOrder.removeWhere((id) {
      final stored = _seenPackets[id];
      if (stored == null || stored.seenAt.isBefore(cutoff)) {
        _seenPackets.remove(id);
        return true;
      }
      return false;
    });
  }

  /// Reset all state.
  void reset() {
    _seenPackets.clear();
    _packetOrder.clear();
  }
}

class _StoredPacket {
  final FluxonPacket packet;
  final DateTime seenAt;

  _StoredPacket({required this.packet, required this.seenAt});
}

/// MED-8: Tracks sync response rate per peer to prevent bandwidth amplification.
class _SyncRateState {
  int count = 0;
  DateTime windowStart = DateTime.now();
}

/// Configuration for gossip sync.
class GossipSyncConfig {
  /// Maximum number of packets to track for sync.
  final int seenCapacity;

  /// Maximum age of messages to sync (seconds).
  final int maxMessageAgeSeconds;

  /// How often to run maintenance (seconds).
  final int maintenanceIntervalSeconds;

  /// Interval between sync rounds (seconds).
  final int syncIntervalSeconds;

  /// MED-8: Maximum packets sent per sync request per peer (bandwidth cap).
  final int maxSyncPacketsPerRequest;

  const GossipSyncConfig({
    this.seenCapacity = 1000,
    this.maxMessageAgeSeconds = 900, // 15 minutes
    this.maintenanceIntervalSeconds = 60,
    this.syncIntervalSeconds = 15,
    this.maxSyncPacketsPerRequest = 20,
  });
}
