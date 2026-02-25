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

  /// Ed25519 signing public keys cached from peer connections, keyed by peer hex ID.
  /// LRU-ordered (LinkedHashMap insertion order): oldest entry is evicted when limit exceeded.
  final LinkedHashMap<String, Uint8List> _peerSigningKeys = LinkedHashMap();
  static const _maxPeerSigningKeys = 500;

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
    // Enforce Ed25519 signature verification for non-handshake packets.
    // Handshake packets are exempt because the signing key is exchanged during
    // the handshake itself.
    if (packet.type != MessageType.handshake) {
      final signingKey = _peerSigningKeys[HexUtils.encode(packet.sourceId)];
      if (signingKey != null) {
        // We know this peer's signing key — the packet MUST carry a valid signature.
        if (packet.signature == null) {
          SecureLogger.warning(
            'Packet from ${HexUtils.encode(packet.sourceId)} has no signature but signing key is known — dropping',
            category: _cat,
          );
          return; // Drop unsigned packet from known peer
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
          return; // Drop forged packet
        }
      } else {
        // CRIT-3 (partial mitigation): Signing key not yet available.
        // Note: for multi-hop relay, packets from distant nodes legitimately
        // arrive before their signing key is cached. BleTransport already
        // enforces that DIRECT connections without Noise sessions are rejected
        // (see BleTransport C4). Here we log and accept provisionally for
        // relay compatibility. Once the signing key is learned (via handshake
        // or topology announce), all subsequent packets from this source are
        // fully verified.
        SecureLogger.debug(
          'Accepting ${packet.type.name} from unverified peer provisionally',
          category: _cat,
        );
      }
    }

    // Feed to gossip sync for gap-filling bookkeeping.
    _gossipSync.onPacketSeen(packet);

    // Mesh-internal packet types: update topology, relay, but don't emit.
    if (packet.type == MessageType.discovery ||
        packet.type == MessageType.topologyAnnounce) {
      _handleTopologyPacket(packet);
      _maybeRelay(packet);
      return;
    }

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
    final isMine = bytesEqual(packet.sourceId, _myPeerId);

    final decision = RelayController.decide(
      ttl: packet.ttl,
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
    final neighborIds = _currentPeers.map((p) => p.peerId).toList();
    final payload = BinaryProtocol.encodeDiscoveryPayload(
      neighbors: neighborIds,
    );
    final packet = BinaryProtocol.buildPacket(
      type: type,
      sourceId: _myPeerId,
      payload: payload,
      ttl: FluxonPacket.maxTTL,
    );
    await _rawTransport.broadcastPacket(packet);
  }

}
