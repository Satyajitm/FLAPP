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

  /// Directed claims: Key claims to see Value (neighbors).
  final Map<String, Set<String>> _claims = {};

  /// Last time we received an update from a node.
  final Map<String, DateTime> _lastSeen = {};

  /// Update the topology with a node's self-reported neighbor list.
  void updateNeighbors({required Uint8List source, required List<Uint8List> neighbors}) {
    final srcId = _sanitize(source);
    if (srcId == null) return;

    final validNeighbors = <String>{};
    for (final n in neighbors) {
      final nId = _sanitize(n);
      if (nId != null && nId != srcId) {
        validNeighbors.add(nId);
      }
    }

    _claims[srcId] = validNeighbors;
    _lastSeen[srcId] = DateTime.now();
  }

  /// Remove a peer from the topology.
  void removePeer(Uint8List peerId) {
    final id = _sanitize(peerId);
    if (id == null) return;
    _claims.remove(id);
    _lastSeen.remove(id);
  }

  /// Prune nodes that haven't updated their topology in [age].
  void prune(Duration age) {
    final deadline = DateTime.now().subtract(age);
    final stale = _lastSeen.entries
        .where((e) => e.value.isBefore(deadline))
        .map((e) => e.key)
        .toList();
    for (final peer in stale) {
      _claims.remove(peer);
      _lastSeen.remove(peer);
    }
  }

  /// Compute the shortest route from [start] to [goal] using BFS.
  ///
  /// Returns a list of intermediate hop IDs (excluding start and goal),
  /// or null if no route exists. Returns empty list for direct neighbors.
  List<Uint8List>? computeRoute({
    required Uint8List start,
    required Uint8List goal,
    int maxHops = 10,
  }) {
    final source = _sanitize(start);
    final target = _sanitize(goal);
    if (source == null || target == null) return null;
    if (source == target) return []; // Direct connection

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
          // Return only intermediate hops (excluding source and target)
          return nextPath
              .sublist(1, nextPath.length - 1)
              .map((id) => HexUtils.decode(id))
              .toList();
        }

        visited.add(neighbor);
        queue.add(nextPath);
      }
    }

    return null; // No route found
  }

  /// Reset all topology state.
  void reset() {
    _claims.clear();
    _lastSeen.clear();
  }

  /// Number of known nodes in the topology.
  int get nodeCount => _claims.length;

  /// Sanitize a peer ID to a fixed-size routing ID (hex string).
  String? _sanitize(Uint8List? data) {
    if (data == null || data.isEmpty) return null;

    Uint8List normalized;
    if (data.length > routingIdSize) {
      normalized = Uint8List.sublistView(data, 0, routingIdSize);
    } else if (data.length < routingIdSize) {
      normalized = Uint8List(routingIdSize);
      normalized.setAll(0, data);
    } else {
      normalized = data;
    }

    return HexUtils.encode(normalized);
  }
}
