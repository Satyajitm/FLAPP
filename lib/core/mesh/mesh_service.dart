import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../shared/hex_utils.dart';
import '../../shared/logger.dart';
import '../crypto/signatures.dart';
import '../identity/identity_manager.dart';
import '../protocol/binary_protocol.dart';
import '../protocol/message_types.dart';
import '../protocol/packet.dart';
import '../transport/transport.dart';
import '../transport/transport_config.dart';
import 'deduplicator.dart';
import 'gossip_sync.dart';
import 'relay_controller.dart';
import 'topology_tracker.dart';

/// Mesh relay orchestrator that sits between raw [Transport] and the
/// application layer.
///
/// Implements [Transport] so it can be injected as a drop-in replacement —
/// repositories and controllers need zero changes. Internally it subscribes
/// to the raw transport's packet stream, applies relay logic, updates the
/// topology tracker, and feeds the gossip sync manager.
///
/// Only application-layer packets (chat, location, emergency, etc.) are
/// emitted on [onPacketReceived]. Mesh-internal packets (discovery,
/// topologyAnnounce) are consumed silently.
class MeshService implements Transport {
  final Transport _rawTransport;
  final Uint8List _myPeerId;
  final TransportConfig _config;
  final IdentityManager _identityManager;

  final TopologyTracker _topology;
  final GossipSyncManager _gossipSync;

  /// Application-layer packet stream (filtered — no mesh-internal packets).
  final _appPacketController = StreamController<FluxonPacket>.broadcast();

  StreamSubscription<FluxonPacket>? _packetSub;
  StreamSubscription<List<PeerConnection>>? _peersSub;

  Timer? _announceTimer;
  Timer? _pruneTimer;

  List<PeerConnection> _currentPeers = [];

  /// Set to true in [start] and false at the very beginning of [stop].
  /// Prevents in-flight [_maybeRelay] async calls from broadcasting after stop.
  bool _running = false;

  /// Ed25519 signing public keys cached from peer connections, keyed by peer hex ID.
  /// LRU-ordered (LinkedHashMap insertion order): oldest entry is evicted when limit exceeded.
  final LinkedHashMap<String, Uint8List> _peerSigningKeys = LinkedHashMap();
  static const _maxPeerSigningKeys = 500;

  /// Per-source handshake rate limiting: max 3 handshakes per sourceId per 60s.
  /// LRU-capped at 200 entries to prevent memory exhaustion from spoofed source IDs.
  final LinkedHashMap<String, _HandshakeRateState> _handshakeRateBySource =
      LinkedHashMap();
  static const _maxHandshakeRateSources = 200;
  static const _maxHandshakesPerWindow = 3;

  /// M1: Packet-level deduplicator — drops packets already seen at the mesh layer.
  final MessageDeduplicator _meshDedup = MessageDeduplicator(
    maxAge: const Duration(seconds: 300),
    maxCount: 1000,
  );

  static const _cat = 'Mesh';

  MeshService({
    required Transport transport,
    required Uint8List myPeerId,
    required IdentityManager identityManager,
    TransportConfig config = TransportConfig.defaultConfig,
    TopologyTracker? topologyTracker,
    GossipSyncManager? gossipSync,
  })  : _rawTransport = transport,
        _myPeerId = myPeerId,
        _identityManager = identityManager,
        _config = config,
        _topology = topologyTracker ?? TopologyTracker(),
        _gossipSync = gossipSync ??
            GossipSyncManager(
              myPeerId: myPeerId,
              transport: transport,
            );

  // ---------------------------------------------------------------------------
  // Transport interface (delegates to raw transport for sending)
  // ---------------------------------------------------------------------------

  @override
  Uint8List get myPeerId => _myPeerId;

  @override
  bool get isRunning => _rawTransport.isRunning;

  @override
  Stream<FluxonPacket> get onPacketReceived => _appPacketController.stream;

  @override
  Stream<List<PeerConnection>> get connectedPeers =>
      _rawTransport.connectedPeers;

  @override
  Future<void> startServices() async {
    await _rawTransport.startServices();
    await start();
  }

  @override
  Future<void> stopServices() async {
    await stop();
    await _rawTransport.stopServices();
  }

  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async {
    FluxonPacket outgoing = packet;
    try {
      final sig = Signatures.sign(packet.encode(), _identityManager.signingPrivateKey);
      outgoing = packet.withSignature(sig);
    } catch (_) {
      // Sodium not available (test / desktop) — send unsigned.
    }
    return _rawTransport.sendPacket(outgoing, peerId);
  }

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    FluxonPacket outgoing = packet;
    try {
      final sig = Signatures.sign(packet.encode(), _identityManager.signingPrivateKey);
      outgoing = packet.withSignature(sig);
    } catch (_) {
      // Sodium not available (test / desktop) — broadcast unsigned.
    }
    await _rawTransport.broadcastPacket(outgoing);
  }

  /// Expose topology for optional UI / debugging.
  TopologyTracker get topology => _topology;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start listening for packets and peers, and begin periodic announces.
  Future<void> start() async {
    _running = true;
    _packetSub = _rawTransport.onPacketReceived.listen(_onPacketReceived);
    _peersSub = _rawTransport.connectedPeers.listen(_onPeersChanged);
    _gossipSync.start();

    // Periodic topology announce (every 45 seconds).
    // Also triggered immediately on peer list change via _onPeersChanged.
    _announceTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _sendTopologyAnnounce(),
    );

    // Periodic topology prune (every 60 seconds).
    _pruneTimer = Timer.periodic(
      Duration(seconds: _config.topologyFreshnessSeconds),
      (_) => _topology.prune(
        Duration(seconds: _config.topologyFreshnessSeconds),
      ),
    );

    SecureLogger.info('MeshService started', category: _cat);
  }

  /// Stop all subscriptions and timers.
  Future<void> stop() async {
    _running = false; // Set first — guards all in-flight _maybeRelay calls.
    _packetSub?.cancel();
    _packetSub = null;
    _peersSub?.cancel();
    _peersSub = null;
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _gossipSync.stop();

    SecureLogger.info('MeshService stopped', category: _cat);
  }

  Future<void> dispose() async {
    await stop();
    _appPacketController.close();
  }

  // ---------------------------------------------------------------------------
  // Packet handling
  // ---------------------------------------------------------------------------

  void _onPacketReceived(FluxonPacket packet) {
    // M1: Drop packets already seen at the mesh layer (deduplication).
    if (_meshDedup.isDuplicate(packet.packetId)) {
      return;
    }

    // Determine whether this packet has a valid signature.
    // Handshake packets are exempt (signing key is exchanged during handshake).
    bool verified = packet.type == MessageType.handshake;
    if (!verified) {
      final signingKey = _peerSigningKeys[HexUtils.encode(packet.sourceId)];
      if (signingKey != null) {
        // We know this peer's signing key — the packet MUST carry a valid signature.
        if (packet.signature == null) {
          SecureLogger.warning(
            'Packet from ${HexUtils.encode(packet.sourceId)} has no signature but signing key is known — dropping',
            category: _cat,
          );
          return; // Drop unsigned packet from known peer entirely (no relay)
        }
        final valid = Signatures.verify(
          packet.encode(),
          packet.signature!,
          signingKey,
        );
        if (!valid) {
          SecureLogger.warning(
            'Packet from ${HexUtils.encode(packet.sourceId)} has invalid signature — dropping',
            category: _cat,
          );
          return; // Drop forged packet entirely (no relay)
        }
        verified = true;
      }
      // If signing key not yet known: we still relay (multi-hop requirement)
      // but we do NOT emit to the application layer for non-bootstrap types.
      // This is MED-C6: unverified app-layer data is not delivered to repositories.
    }

    // C1: Mesh-internal packet types: update topology only from verified peers.
    // Unverified discovery/topology packets are relayed (TTL will expire)
    // but must NOT influence our topology state to prevent poisoning.
    if (packet.type == MessageType.discovery ||
        packet.type == MessageType.topologyAnnounce) {
      if (verified) {
        _handleTopologyPacket(packet);
        // Record verified topology packets for gossip gap-filling.
        _gossipSync.onPacketSeen(packet);
      } else {
        SecureLogger.debug(
          'Dropping topology/discovery update from unverified peer '
          '${HexUtils.encode(packet.sourceId).substring(0, 8)}…',
          category: _cat,
        );
      }
      _maybeRelay(packet);
      return;
    }

    // Handshake rate limiting per sourceId (MESH-M3).
    // BleTransport rate-limits direct handshakes, but multi-hop relayed
    // handshakes bypass that check. Apply a per-source limit here.
    if (packet.type == MessageType.handshake) {
      final srcKey = HexUtils.encode(packet.sourceId);
      final now = DateTime.now();
      // LRU cap: evict oldest when over limit.
      if (!_handshakeRateBySource.containsKey(srcKey) &&
          _handshakeRateBySource.length >= _maxHandshakeRateSources) {
        _handshakeRateBySource.remove(_handshakeRateBySource.keys.first);
      }
      final hs = _handshakeRateBySource.putIfAbsent(
        srcKey,
        () => _HandshakeRateState(),
      );
      if (now.difference(hs.windowStart).inSeconds >= 60) {
        hs.count = 0;
        hs.windowStart = now;
      }
      if (hs.count >= _maxHandshakesPerWindow) {
        SecureLogger.debug(
          'Handshake rate limit exceeded for source ${srcKey.substring(0, 8)}…',
          category: _cat,
        );
        return; // Drop but do not relay — limit mesh-wide handshake storm.
      }
      hs.count++;
    }

    // MED-C6: Drop application-layer packets from *directly connected* peers
    // whose signing key is not yet known. Multi-hop relayed packets (where the
    // source peer is not in our direct-connection list) are still delivered
    // because we cannot do a Noise handshake with distant nodes.
    if (!verified) {
      final sourceIdHex = HexUtils.encode(packet.sourceId);
      final isDirectPeer = _currentPeers.any((p) => p.peerIdHex == sourceIdHex);
      if (isDirectPeer) {
        SecureLogger.debug(
          'Dropping ${packet.type.name} from unverified direct peer (no signing key yet)',
          category: _cat,
        );
        _maybeRelay(packet); // Still relay — TTL will expire naturally
        return;
      }
      // Not a direct peer: allow delivery (relayed packet from distant node).
      SecureLogger.debug(
        'Accepting relayed ${packet.type.name} from unknown distant peer provisionally',
        category: _cat,
      );
    }

    // Feed verified (or trusted distant-peer) packets to gossip sync.
    // Cross-module fix: gossip sync is called AFTER all drop decisions so that
    // unverified direct-peer packets dropped above are not recorded and later
    // re-sent to other peers via gossip responses.
    _gossipSync.onPacketSeen(packet);

    // Application-layer packet: emit to feature repositories.
    _appPacketController.add(packet);

    // Also consider relaying.
    _maybeRelay(packet);
  }

  void _handleTopologyPacket(FluxonPacket packet) {
    final discovery = BinaryProtocol.decodeDiscoveryPayload(packet.payload);
    if (discovery == null) return;

    _topology.updateNeighbors(
      source: packet.sourceId,
      neighbors: discovery.neighbors,
    );

    SecureLogger.debug(
      'Topology update from ${HexUtils.encode(packet.sourceId).substring(0, 8)}… '
      'with ${discovery.neighbors.length} neighbors',
      category: _cat,
    );
  }

  // ---------------------------------------------------------------------------
  // Relay logic
  // ---------------------------------------------------------------------------

  Future<void> _maybeRelay(FluxonPacket packet) async {
    if (!_running) return; // Guard 1: stop() already called.

    final isMine = bytesEqual(packet.sourceId, _myPeerId);

    // MESH-M3: Cap handshake relay TTL to 3 to limit mesh-wide blast radius
    // of injected handshake packets. Normal packets use their original TTL.
    final effectiveTTL = packet.type == MessageType.handshake
        ? packet.ttl.clamp(0, 3)
        : packet.ttl;

    final decision = RelayController.decide(
      ttl: effectiveTTL,
      senderIsSelf: isMine,
      type: packet.type,
      isDirected: !packet.isBroadcast,
      degree: _currentPeers.length,
    );

    if (!decision.shouldRelay) return;

    // Apply jitter delay.
    if (decision.delayMs > 0) {
      await Future.delayed(Duration(milliseconds: decision.delayMs));
    }

    if (!_running) return; // Guard 2: stop() was called during jitter delay.

    // Create relayed copy preserving original source/timestamp/signature.
    final relayed = FluxonPacket(
      type: packet.type,
      ttl: decision.newTTL,
      flags: packet.flags,
      timestamp: packet.timestamp,
      sourceId: Uint8List.fromList(packet.sourceId),
      destId: Uint8List.fromList(packet.destId),
      payload: Uint8List.fromList(packet.payload),
      signature:
          packet.signature != null ? Uint8List.fromList(packet.signature!) : null,
    );

    await _rawTransport.broadcastPacket(relayed);

    SecureLogger.debug(
      'Relayed ${packet.type.name} TTL ${packet.ttl}→${decision.newTTL} '
      'delay ${decision.delayMs}ms',
      category: _cat,
    );
  }

  // ---------------------------------------------------------------------------
  // Peer change handling + discovery announcements
  // ---------------------------------------------------------------------------

  void _onPeersChanged(List<PeerConnection> peers) {
    final oldIds = _currentPeers.map((p) => p.peerIdHex).toSet();
    final newIds = peers.map((p) => p.peerIdHex).toSet();

    _currentPeers = peers;

    // Cache Ed25519 signing public keys from peer connections (LRU, capped at 500)
    for (final peer in peers) {
      if (peer.signingPublicKey != null) {
        // Re-insert to mark as recently used
        _peerSigningKeys.remove(peer.peerIdHex);
        _peerSigningKeys[peer.peerIdHex] = peer.signingPublicKey!;
        // Evict oldest entry if over limit
        while (_peerSigningKeys.length > _maxPeerSigningKeys) {
          _peerSigningKeys.remove(_peerSigningKeys.keys.first);
        }
      }
    }

    // Update our own topology entry with current neighbor list.
    _topology.updateNeighbors(
      source: _myPeerId,
      neighbors: peers.map((p) => p.peerId).toList(),
    );

    // On any peer list change, send both a discovery and topology announce.
    final justConnected = newIds.difference(oldIds);
    final justDisconnected = oldIds.difference(newIds);
    if (justConnected.isNotEmpty || justDisconnected.isNotEmpty) {
      _sendDiscoveryAnnounce();
      _sendTopologyAnnounce();
    }
  }

  Future<void> _sendDiscoveryAnnounce() =>
      _sendAnnounce(MessageType.discovery);

  Future<void> _sendTopologyAnnounce() =>
      _sendAnnounce(MessageType.topologyAnnounce);

  /// Shared implementation for discovery and topology announce packets.
  ///
  /// Both packets carry the same neighbor-list payload; only the [type] differs.
  Future<void> _sendAnnounce(MessageType type) async {
    // Cap neighbor list to the protocol maximum (matches the decode-side guard
    // in decodeDiscoveryPayload which rejects neighborCount > 10).
    final allNeighborIds = _currentPeers.map((p) => p.peerId).toList();
    final neighborIds = allNeighborIds.length > 10
        ? allNeighborIds.sublist(0, 10)
        : allNeighborIds;
    final payload = BinaryProtocol.encodeDiscoveryPayload(
      neighbors: neighborIds,
    );
    final packet = BinaryProtocol.buildPacket(
      type: type,
      sourceId: _myPeerId,
      payload: payload,
      ttl: FluxonPacket.maxTTL,
    );
    // C3: Use MeshService.broadcastPacket (self) so the packet is signed
    // with our Ed25519 key before going on the wire.
    await broadcastPacket(packet);
  }

}

/// Per-source handshake rate-limit state for [MeshService._handshakeRateBySource].
class _HandshakeRateState {
  int count = 0;
  DateTime windowStart = DateTime.now();
}
