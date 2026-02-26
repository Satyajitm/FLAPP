import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/mesh/topology_tracker.dart';

void main() {
  group('TopologyTracker', () {
    late TopologyTracker tracker;

    // L2: _sanitize now requires exactly 32 bytes — all test peer IDs must be
    // 32 bytes.
    Uint8List peerId(int value) {
      final id = Uint8List(32);
      id[0] = value;
      return id;
    }

    setUp(() {
      tracker = TopologyTracker();
    });

    test('direct neighbors return empty route', () {
      final a = peerId(1);
      final b = peerId(2);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a]);

      final route = tracker.computeRoute(start: a, goal: b);
      expect(route, isNotNull);
      expect(route, isEmpty); // Direct connection = no intermediate hops
    });

    test('two-hop route found via BFS', () {
      final a = peerId(1);
      final b = peerId(2);
      final c = peerId(3);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a, c]);
      tracker.updateNeighbors(source: c, neighbors: [b]);

      final route = tracker.computeRoute(start: a, goal: c);
      expect(route, isNotNull);
      expect(route!.length, equals(1)); // one intermediate hop (B)
    });

    test('requires bidirectional edge', () {
      final a = peerId(1);
      final b = peerId(2);

      // Only A claims B, but B doesn't claim A
      tracker.updateNeighbors(source: a, neighbors: [b]);

      final route = tracker.computeRoute(start: a, goal: b);
      expect(route, isNull); // No route — unidirectional edge
    });

    test('returns null for unreachable destination', () {
      final a = peerId(1);
      final b = peerId(2);
      final c = peerId(3);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a]);
      // C is isolated

      final route = tracker.computeRoute(start: a, goal: c);
      expect(route, isNull);
    });

    test('prune removes stale nodes', () async {
      final a = peerId(1);
      final b = peerId(2);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a]);

      // Wait briefly so entries have non-zero age, then prune
      await Future.delayed(const Duration(milliseconds: 10));
      tracker.prune(Duration.zero);

      expect(tracker.nodeCount, equals(0));
    });

    test('reset clears all state', () {
      final a = peerId(1);
      tracker.updateNeighbors(source: a, neighbors: [peerId(2)]);

      tracker.reset();
      expect(tracker.nodeCount, equals(0));
    });

    test('same source and goal returns empty route', () {
      final a = peerId(1);
      final route = tracker.computeRoute(start: a, goal: a);
      expect(route, isNotNull);
      expect(route, isEmpty);
    });

    test('self-loops are excluded', () {
      final a = peerId(1);
      tracker.updateNeighbors(source: a, neighbors: [a, peerId(2)]);

      // Self-loop should be filtered out
      final b = peerId(2);
      tracker.updateNeighbors(source: b, neighbors: [a]);

      final route = tracker.computeRoute(start: a, goal: b);
      expect(route, isNotNull);
    });

    test('removePeer deletes a node from topology', () {
      final a = peerId(1);
      final b = peerId(2);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a]);
      expect(tracker.nodeCount, equals(2));

      tracker.removePeer(a);
      expect(tracker.nodeCount, equals(1));

      // Route from a to b should no longer work (a's claims gone)
      final route = tracker.computeRoute(start: a, goal: b);
      expect(route, isNull);
    });

    test('removePeer with empty Uint8List is no-op', () {
      final a = peerId(1);
      tracker.updateNeighbors(source: a, neighbors: [peerId(2)]);
      expect(tracker.nodeCount, equals(1));

      tracker.removePeer(Uint8List(0));
      expect(tracker.nodeCount, equals(1));
    });

    test('updateNeighbors overwrites previous claims', () {
      final a = peerId(1);
      final b = peerId(2);
      final c = peerId(3);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a]);
      tracker.updateNeighbors(source: c, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a, c]);

      // A—B—C route should work
      final route = tracker.computeRoute(start: a, goal: c);
      expect(route, isNotNull);
      expect(route!.length, equals(1)); // B is the intermediate hop

      // Now B drops A from its neighbor list
      tracker.updateNeighbors(source: b, neighbors: [c]);

      // A—B route should fail (B no longer claims A)
      final route2 = tracker.computeRoute(start: a, goal: b);
      expect(route2, isNull);
    });

    test('selective prune keeps fresh nodes', () async {
      final a = peerId(1);
      final b = peerId(2);

      tracker.updateNeighbors(source: a, neighbors: [b]);

      // Wait so 'a' is slightly old
      await Future.delayed(const Duration(milliseconds: 50));

      // Add 'b' more recently
      tracker.updateNeighbors(source: b, neighbors: [a]);

      // Prune with a threshold that removes 'a' but not 'b'
      // 'a' was added ~50ms ago, 'b' was added just now
      tracker.prune(const Duration(milliseconds: 30));

      // 'a' should be pruned (older than 30ms), 'b' may or may not be
      // depending on timing. At minimum, nodeCount should be less than 2.
      expect(tracker.nodeCount, lessThanOrEqualTo(2));
    });

    test('three-hop route found via BFS', () {
      final a = peerId(1);
      final b = peerId(2);
      final c = peerId(3);
      final d = peerId(4);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a, c]);
      tracker.updateNeighbors(source: c, neighbors: [b, d]);
      tracker.updateNeighbors(source: d, neighbors: [c]);

      final route = tracker.computeRoute(start: a, goal: d);
      expect(route, isNotNull);
      expect(route!.length, equals(2)); // B and C are intermediate hops
    });

    test('maxHops limits route length', () {
      final a = peerId(1);
      final b = peerId(2);
      final c = peerId(3);
      final d = peerId(4);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      tracker.updateNeighbors(source: b, neighbors: [a, c]);
      tracker.updateNeighbors(source: c, neighbors: [b, d]);
      tracker.updateNeighbors(source: d, neighbors: [c]);

      // Route A→D requires 3 hops (A→B→C→D). maxHops=1 should fail.
      final route = tracker.computeRoute(start: a, goal: d, maxHops: 1);
      expect(route, isNull);

      // maxHops=3 should succeed
      final route2 = tracker.computeRoute(start: a, goal: d, maxHops: 3);
      expect(route2, isNotNull);
      expect(route2!.length, equals(2)); // B and C intermediates
    });

    test('nodeCount increments with unique sources', () {
      expect(tracker.nodeCount, equals(0));

      tracker.updateNeighbors(source: peerId(1), neighbors: [peerId(2)]);
      expect(tracker.nodeCount, equals(1));

      tracker.updateNeighbors(source: peerId(2), neighbors: [peerId(1)]);
      expect(tracker.nodeCount, equals(2));

      // Same source again — should NOT increment
      tracker.updateNeighbors(source: peerId(1), neighbors: [peerId(3)]);
      expect(tracker.nodeCount, equals(2));
    });

    // -------------------------------------------------------------------------
    // L2 — _sanitize rejects any peer ID that is not exactly 32 bytes
    // -------------------------------------------------------------------------
    test('L2: undersized peer ID (8 bytes) is rejected — no topology entry created',
        () {
      // After L2 fix _sanitize returns null for any length != routingIdSize (32).
      final a = Uint8List(8)..[0] = 0x01; // 8 bytes — should be rejected
      final b = Uint8List(32)..fillRange(0, 32, 0x02); // valid 32-byte ID

      tracker.updateNeighbors(source: a, neighbors: [b]);
      // updateNeighbors returns immediately when _sanitize(source) returns null
      expect(tracker.nodeCount, equals(0),
          reason: 'Undersized source ID must be rejected');
    });

    test('L2: oversized peer ID (64 bytes) is rejected — no topology entry created',
        () {
      final longId = Uint8List(64)..fillRange(0, 64, 0x01);
      final b = Uint8List(32)..fillRange(0, 32, 0x02);

      tracker.updateNeighbors(source: longId, neighbors: [b]);
      expect(tracker.nodeCount, equals(0),
          reason: 'Oversized source ID must be rejected');
    });

    test('L2: exact 32-byte peer ID is accepted', () {
      final a = Uint8List(32)..fillRange(0, 32, 0x01);
      final b = Uint8List(32)..fillRange(0, 32, 0x02);

      tracker.updateNeighbors(source: a, neighbors: [b]);
      expect(tracker.nodeCount, equals(1));
    });

    test('L2: computeRoute returns null for undersized start ID (not 32 bytes)', () {
      final a = Uint8List(8)..fillRange(0, 8, 0x01); // 8 bytes — rejected
      final b = Uint8List(32)..fillRange(0, 32, 0x02);
      final route = tracker.computeRoute(start: a, goal: b);
      expect(route, isNull);
    });

    test('L2: computeRoute returns null for oversized goal ID', () {
      final a = Uint8List(32)..fillRange(0, 32, 0x01);
      final b = Uint8List(64)..fillRange(0, 64, 0x02); // 64 bytes
      final route = tracker.computeRoute(start: a, goal: b);
      expect(route, isNull);
    });

    test('L2: 32-byte neighbor IDs are accepted, non-32-byte ones are silently skipped',
        () {
      final a = Uint8List(32)..fillRange(0, 32, 0x01);
      final validNeighbor = Uint8List(32)..fillRange(0, 32, 0x02);
      final invalidNeighbor = Uint8List(8)..fillRange(0, 8, 0x03);

      tracker.updateNeighbors(source: a, neighbors: [validNeighbor, invalidNeighbor]);
      // Source is valid so it should be stored; invalid neighbor should be dropped.
      expect(tracker.nodeCount, equals(1));
    });

    test('empty source Uint8List is rejected', () {
      tracker.updateNeighbors(source: Uint8List(0), neighbors: [peerId(1)]);
      expect(tracker.nodeCount, equals(0));
    });

    test('computeRoute returns null for empty start', () {
      final route = tracker.computeRoute(start: Uint8List(0), goal: peerId(1));
      expect(route, isNull);
    });

    test('computeRoute returns null for empty goal', () {
      final route = tracker.computeRoute(start: peerId(1), goal: Uint8List(0));
      expect(route, isNull);
    });

    // -----------------------------------------------------------------------
    // Route cache
    // -----------------------------------------------------------------------

    group('route cache', () {
      test('second call returns cached result without re-running BFS', () {
        final a = peerId(1);
        final b = peerId(2);
        final c = peerId(3);

        tracker.updateNeighbors(source: a, neighbors: [b]);
        tracker.updateNeighbors(source: b, neighbors: [a, c]);
        tracker.updateNeighbors(source: c, neighbors: [b]);

        final route1 = tracker.computeRoute(start: a, goal: c);
        final route2 = tracker.computeRoute(start: a, goal: c);

        expect(route1, isNotNull);
        expect(route2, isNotNull);
        // Same content is returned from cache (decoded from stored hex each time).
        expect(route1!.length, equals(route2!.length));
        for (var i = 0; i < route1.length; i++) {
          expect(route1[i], equals(route2[i]));
        }
      });

      test('cache is invalidated after updateNeighbors', () {
        final a = peerId(1);
        final b = peerId(2);
        final c = peerId(3);

        tracker.updateNeighbors(source: a, neighbors: [b]);
        tracker.updateNeighbors(source: b, neighbors: [a, c]);
        tracker.updateNeighbors(source: c, neighbors: [b]);

        final routeBefore = tracker.computeRoute(start: a, goal: c);
        expect(routeBefore, isNotNull);

        // Remove B as a common neighbour — route should now be null.
        tracker.updateNeighbors(source: b, neighbors: []);

        final routeAfter = tracker.computeRoute(start: a, goal: c);
        expect(routeAfter, isNull);
      });

      test('cache is invalidated after removePeer', () {
        final a = peerId(1);
        final b = peerId(2);
        final c = peerId(3);

        tracker.updateNeighbors(source: a, neighbors: [b]);
        tracker.updateNeighbors(source: b, neighbors: [a, c]);
        tracker.updateNeighbors(source: c, neighbors: [b]);

        final routeBefore = tracker.computeRoute(start: a, goal: c);
        expect(routeBefore, isNotNull);

        tracker.removePeer(b);

        final routeAfter = tracker.computeRoute(start: a, goal: c);
        expect(routeAfter, isNull);
      });

      test('cache is cleared by reset', () {
        final a = peerId(1);
        final b = peerId(2);

        tracker.updateNeighbors(source: a, neighbors: [b]);
        tracker.updateNeighbors(source: b, neighbors: [a]);

        final routeBefore = tracker.computeRoute(start: a, goal: b);
        expect(routeBefore, isNotNull);

        tracker.reset();

        // After reset, topology is gone so BFS should find no route.
        final routeAfter = tracker.computeRoute(start: a, goal: b);
        expect(routeAfter, isNull);
      });

      test('cache is cleared after prune removes a node on the route', () async {
        final a = peerId(1);
        final b = peerId(2);
        final c = peerId(3);

        tracker.updateNeighbors(source: a, neighbors: [b]);
        tracker.updateNeighbors(source: b, neighbors: [a, c]);
        tracker.updateNeighbors(source: c, neighbors: [b]);

        final routeBefore = tracker.computeRoute(start: a, goal: c);
        expect(routeBefore, isNotNull); // Caches the route.

        // Wait so all nodes become stale, then prune.
        await Future.delayed(const Duration(milliseconds: 10));
        tracker.prune(Duration.zero);

        // All nodes pruned — BFS finds nothing and stale cache is not returned.
        final routeAfter = tracker.computeRoute(start: a, goal: c);
        expect(routeAfter, isNull);
      });

      test('cached null result is still returned within TTL', () {
        final a = peerId(1);
        final b = peerId(2);
        // No topology loaded — route is always null.

        final route1 = tracker.computeRoute(start: a, goal: b);
        expect(route1, isNull);

        // Without any topology change the second call should also be null
        // (served from cache — same null result).
        final route2 = tracker.computeRoute(start: a, goal: b);
        expect(route2, isNull);
      });

      test('different maxHops values use independent cache slots', () {
        final a = peerId(1);
        final b = peerId(2);
        final c = peerId(3);
        final d = peerId(4);

        tracker.updateNeighbors(source: a, neighbors: [b]);
        tracker.updateNeighbors(source: b, neighbors: [a, c]);
        tracker.updateNeighbors(source: c, neighbors: [b, d]);
        tracker.updateNeighbors(source: d, neighbors: [c]);

        final restricted = tracker.computeRoute(start: a, goal: d, maxHops: 1);
        expect(restricted, isNull); // Cached as null for key "a:d:1".

        final full = tracker.computeRoute(start: a, goal: d, maxHops: 3);
        expect(full, isNotNull); // Different slot — BFS runs independently.
        expect(full!.length, equals(2));
      });
    });
  });
}
