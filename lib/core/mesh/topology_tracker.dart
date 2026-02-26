import 'dart:collection';
import 'dart:typed_data';
import '../../shared/hex_utils.dart';

/// Tracks observed mesh topology and computes hop-by-hop routes.
///
/// Ported from Bitchat's MeshTopologyTracker.
/// Uses two-way edge verification and BFS shortest-path routing.
class TopologyTracker {
  /// Routing ID size in bytes (must match full peer ID size).
  static const int routingIdSize = 32;

  /// Maximum age for topology claims to be considered fresh for routing.
  static const Duration routeFreshnessThreshold = Duration(seconds: 60);

  /// Maximum number of neighbors stored per node in the topology.
  /// Enforcement here makes the invariant explicit at the data-structure level,
  /// independent of the BinaryProtocol decode-side cap.
  static const int _maxNeighborsPerNode = 20;

  /// Directed claims: Key claims to see Value (neighbors).
  final Map<String, Set<String>> _claims = {};

  /// Last time we received an update from a node.
  final Map<String, DateTime> _lastSeen = {};

  /// Route cache: "$source:$target:$maxHops" → computed route as hex strings (or null = no route).
  /// Intermediate hops are stored as hex strings to avoid per-invalidation re-encoding.
  /// LRU-ordered LinkedHashMap capped at [_maxRouteCacheEntries].
  final LinkedHashMap<String, ({List<String>? routeHex, DateTime cachedAt})>
      _routeCache = LinkedHashMap();
  static const Duration _routeCacheTtl = Duration(seconds: 5);
  static const int _maxRouteCacheEntries = 500;

  /// Update the topology with a node's self-reported neighbor list.
  void updateNeighbors({required Uint8List source, required List<Uint8List> neighbors}) {
    final srcId = _sanitize(source);
    if (srcId == null) return;

    final validNeighbors = <String>{};
    for (final n in neighbors) {
      final nId = _sanitize(n);
      if (nId != null && nId != srcId) {
        validNeighbors.add(nId);
        // Cap per-node neighbor count regardless of the caller/protocol layer.
        if (validNeighbors.length >= _maxNeighborsPerNode) break;
      }
    }

    _claims[srcId] = validNeighbors;
    _lastSeen[srcId] = DateTime.now();
    // Granular cache invalidation: only remove routes that pass through srcId.
    _invalidateRoutesFor(srcId);
  }

  /// Remove a peer from the topology.
  void removePeer(Uint8List peerId) {
    final id = _sanitize(peerId);
    if (id == null) return;
    _claims.remove(id);
    _lastSeen.remove(id);
    _invalidateRoutesFor(id);
  }

  /// Prune nodes that haven't updated their topology in [age].
  void prune(Duration age) {
    final deadline = DateTime.now().subtract(age);
    final stale = _lastSeen.entries
        .where((e) => e.value.isBefore(deadline))
        .map((e) => e.key)
        .toList();
    if (stale.isEmpty) return;
    for (final peer in stale) {
      _claims.remove(peer);
      _lastSeen.remove(peer);
    }
    // Cached routes may go through pruned nodes — invalidate.
    _routeCache.clear();
  }

  /// Compute the shortest route from [start] to [goal] using BFS.
  ///
  /// Returns a list of intermediate hop IDs (excluding start and goal),
  /// or null if no route exists. Returns empty list for direct neighbors.
  ///
  /// Results are cached for [_routeCacheTtl] and invalidated on topology change.
  List<Uint8List>? computeRoute({
    required Uint8List start,
    required Uint8List goal,
    int maxHops = 10,
  }) {
    final source = _sanitize(start);
    final target = _sanitize(goal);
    if (source == null || target == null) return null;
    if (source == target) return []; // Direct connection

    final cacheKey = '$source:$target:$maxHops';
    // LRU: re-insert on hit to mark as recently used.
    final cached = _routeCache.remove(cacheKey);
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _routeCacheTtl) {
      _routeCache[cacheKey] = cached; // Re-insert as most-recently-used.
      return cached.routeHex?.map(HexUtils.decode).toList();
    }

    final now = DateTime.now();
    final freshnessDeadline = now.subtract(routeFreshnessThreshold);

    // BFS
    final visited = <String>{source};
    final queue = Queue<List<String>>();
    queue.add([source]);

    while (queue.isNotEmpty) {
      final path = queue.removeFirst();
      if (path.length > maxHops + 1) continue;

      final last = path.last;

      // Get neighbors that 'last' claims to see
      final neighbors = _claims[last];
      if (neighbors == null) continue;

      // Check freshness of 'last' node's topology info
      final lastSeenTime = _lastSeen[last];
      if (lastSeenTime == null || lastSeenTime.isBefore(freshnessDeadline)) {
        continue;
      }

      for (final neighbor in neighbors) {
        if (visited.contains(neighbor)) continue;

        // Two-way edge verification: does 'neighbor' also claim 'last'?
        final neighborClaims = _claims[neighbor];
        if (neighborClaims == null || !neighborClaims.contains(last)) continue;

        // Check freshness of neighbor's topology info
        final neighborSeen = _lastSeen[neighbor];
        if (neighborSeen == null || neighborSeen.isBefore(freshnessDeadline)) continue;

        final nextPath = [...path, neighbor];

        if (neighbor == target) {
          // Intermediate hops stored as hex strings — avoids per-invalidation
          // re-encoding in _invalidateRoutesFor (O(n×m) → O(1) per entry).
          final routeHex = nextPath.sublist(1, nextPath.length - 1);
          _insertRouteCache(cacheKey, (routeHex: routeHex, cachedAt: DateTime.now()));
          return routeHex.map(HexUtils.decode).toList();
        }

        visited.add(neighbor);
        queue.add(nextPath);
      }
    }

    _insertRouteCache(cacheKey, (routeHex: null, cachedAt: DateTime.now()));
    return null; // No route found
  }

  /// Insert an entry into the route cache, evicting the LRU entry if at capacity.
  void _insertRouteCache(
      String key, ({List<String>? routeHex, DateTime cachedAt}) value) {
    if (_routeCache.length >= _maxRouteCacheEntries) {
      _routeCache.remove(_routeCache.keys.first); // Evict oldest (LRU front).
    }
    _routeCache[key] = value;
  }

  /// Invalidate only the route cache entries that involve [nodeId].
  ///
  /// Cache keys are "$source:$target:$maxHops". We remove any entry where
  /// [nodeId] appears as the source, target, or as part of the cached route.
  /// Intermediate hops are stored as hex strings so no per-entry re-encoding
  /// is needed — O(hops) string compare instead of O(hops) encode+compare.
  void _invalidateRoutesFor(String nodeId) {
    _routeCache.removeWhere((key, value) {
      // Key format: "source:target:maxHops" — source is first segment.
      final colon1 = key.indexOf(':');
      final colon2 = colon1 >= 0 ? key.indexOf(':', colon1 + 1) : -1;
      if (colon1 >= 0 && colon2 >= 0) {
        if (key.substring(0, colon1) == nodeId ||
            key.substring(colon1 + 1, colon2) == nodeId) {
          return true;
        }
      }
      // Also remove entries whose cached route passes through nodeId.
      // Hops are already hex-encoded strings — no re-encoding needed.
      return value.routeHex?.contains(nodeId) ?? false;
    });
  }

  /// Reset all topology state.
  void reset() {
    _claims.clear();
    _lastSeen.clear();
    _routeCache.clear();
  }

  /// Number of known nodes in the topology.
  int get nodeCount => _claims.length;

  /// Sanitize a peer ID to a fixed-size routing ID (hex string).
  ///
  /// L2: Rejects any peer ID that is not exactly [routingIdSize] bytes.
  /// Previously, undersized IDs were zero-padded and oversized IDs were
  /// truncated; both allowed spoofing / ambiguous identities.
  String? _sanitize(Uint8List? data) {
    if (data == null || data.isEmpty) return null;

    // L2: Exact-size enforcement — reject IDs that are not exactly 32 bytes.
    if (data.length != routingIdSize) return null;

    return HexUtils.encode(data);
  }
}
