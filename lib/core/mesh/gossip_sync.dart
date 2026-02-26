import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import '../../shared/hex_utils.dart';
import '../protocol/message_types.dart';
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

  /// H1: Packet types that should NOT be stored in gossip sync.
  /// Replaying handshake/encrypted/ack/ping/pong packets is harmful
  /// (stale crypto state, bandwidth waste) so we filter them out.
  static const _skipTypes = {
    MessageType.handshake,
    MessageType.noiseEncrypted,
    MessageType.ack,
    MessageType.ping,
    MessageType.pong,
    MessageType.gossipSync,
  };

  /// Record a packet we've seen (either originated or received).
  void onPacketSeen(FluxonPacket packet) {
    // H1: Skip mesh-internal and session-layer packet types.
    if (_skipTypes.contains(packet.type)) return;

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
  /// LRU-ordered LinkedHashMap capped at [_maxSyncRatePeers] entries to prevent
  /// memory exhaustion from attackers using many spoofed source IDs.
  final LinkedHashMap<String, _SyncRateState> _syncRateByPeer = LinkedHashMap();
  static const int _maxSyncRatePeers = 200;

  /// Handle a sync request from a peer.
  ///
  /// MED-8: Rate-limited — max [config.maxSyncPacketsPerRequest] packets per
  /// sync round per peer. Only authenticated peers should call this; the
  /// caller (MeshService) is responsible for enforcing authentication.
  Future<void> handleSyncRequest({
    required Uint8List fromPeerId,
    required Set<String> peerHasIds,
  }) async {
    // Reject oversized peerHasIds sets to prevent unbounded heap allocation
    // from a malicious peer crafting a gossip sync request with 100k+ IDs.
    if (peerHasIds.length > config.seenCapacity * 2) return;

    final now = DateTime.now();
    final cutoff = now.subtract(Duration(seconds: config.maxMessageAgeSeconds));

    // MED-8: Enforce per-peer sync response rate limit.
    final peerKey = HexUtils.encode(fromPeerId);
    // LRU cap: evict oldest entry when the map is full before inserting new peer.
    if (!_syncRateByPeer.containsKey(peerKey) &&
        _syncRateByPeer.length >= _maxSyncRatePeers) {
      _syncRateByPeer.remove(_syncRateByPeer.keys.first);
    }
    final rateState = _syncRateByPeer.putIfAbsent(
      peerKey, () => _SyncRateState(),
    );
    if (now.difference(rateState.windowStart).inSeconds >= 60) {
      rateState.count = 0;
      rateState.windowStart = now;
    }

    // H2: If this peer has already consumed the full window budget, refuse.
    if (rateState.count >= config.maxSyncPacketsPerRequest) return;

    for (final entry in _seenPackets.entries) {
      // Use rateState.count (persists across calls) not a local counter that
      // resets to 0 each call — otherwise the budget is only enforced after
      // the loop has sent a full window's worth in a single call, allowing
      // multiple under-full calls to bypass the cap.
      if (rateState.count >= config.maxSyncPacketsPerRequest) break;
      if (peerHasIds.contains(entry.key)) continue;
      if (entry.value.seenAt.isBefore(cutoff)) continue;

      rateState.count++;

      // Send missing packet to the requesting peer
      final packet = entry.value.packet.withDecrementedTTL();
      await _transport.sendPacket(packet, fromPeerId);
    }
  }

  /// Build a set of packet IDs we currently have (for sync requests).
  ///
  /// Returns an unmodifiable view over the live map keys — no copy allocated.
  /// Callers must not hold the reference across mutations of [_seenPackets].
  Iterable<String> get knownPacketIds => _seenPackets.keys;

  void _performMaintenance() {
    _cleanupExpired();
  }

  void _cleanupExpired() {
    final now = DateTime.now();
    final cutoff = now.subtract(
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

    // M2: Purge stale per-peer rate-limit windows (older than 60 seconds).
    _syncRateByPeer.removeWhere(
      (_, state) => now.difference(state.windowStart).inSeconds >= 60,
    );
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
