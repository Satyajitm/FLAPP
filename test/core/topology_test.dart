import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/mesh/topology_tracker.dart';

void main() {
  group('TopologyTracker', () {
    late TopologyTracker tracker;

    Uint8List peerId(int value) {
      final id = Uint8List(8);
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
  });
}
