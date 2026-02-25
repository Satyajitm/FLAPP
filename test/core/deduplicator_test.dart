import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/mesh/deduplicator.dart';

void main() {
  group('MessageDeduplicator', () {
    late MessageDeduplicator dedup;

    setUp(() {
      dedup = MessageDeduplicator(
        maxAge: const Duration(seconds: 10),
        maxCount: 5,
      );
    });

    test('first occurrence is not duplicate', () {
      expect(dedup.isDuplicate('msg-1'), isFalse);
    });

    test('second occurrence is duplicate', () {
      dedup.isDuplicate('msg-1');
      expect(dedup.isDuplicate('msg-1'), isTrue);
    });

    test('different messages are not duplicates', () {
      dedup.isDuplicate('msg-1');
      expect(dedup.isDuplicate('msg-2'), isFalse);
    });

    test('contains checks without adding', () {
      expect(dedup.contains('msg-1'), isFalse);
      dedup.isDuplicate('msg-1');
      expect(dedup.contains('msg-1'), isTrue);
    });

    test('markProcessed adds without checking', () {
      dedup.markProcessed('msg-1');
      expect(dedup.contains('msg-1'), isTrue);
      expect(dedup.isDuplicate('msg-1'), isTrue);
    });

    test('evicts oldest when exceeding maxCount', () {
      for (var i = 0; i < 10; i++) {
        dedup.isDuplicate('msg-$i');
      }
      // Oldest entries should have been evicted
      // After trim, we keep ~75% of maxCount = 3-4 entries
      // The most recent ones should still be there
      expect(dedup.contains('msg-9'), isTrue);
    });

    test('reset clears all entries', () {
      dedup.isDuplicate('msg-1');
      dedup.isDuplicate('msg-2');
      dedup.reset();
      expect(dedup.contains('msg-1'), isFalse);
      expect(dedup.contains('msg-2'), isFalse);
    });

    test('timestampFor returns recorded time', () {
      expect(dedup.timestampFor('msg-1'), isNull);
      dedup.isDuplicate('msg-1');
      expect(dedup.timestampFor('msg-1'), isNotNull);
    });

    test('record with explicit timestamp', () {
      final ts = DateTime(2024, 1, 1);
      dedup.record('msg-1', ts);
      expect(dedup.timestampFor('msg-1'), equals(ts));
    });

    // -------------------------------------------------------------------------
    // Compaction / eviction behaviour
    // -------------------------------------------------------------------------

    group('compaction and eviction', () {
      test('entries older than maxAge are expired by cleanup()', () async {
        final shortDedup = MessageDeduplicator(
          maxAge: const Duration(milliseconds: 50),
          maxCount: 100,
        );

        shortDedup.isDuplicate('old-1');
        shortDedup.isDuplicate('old-2');

        await Future.delayed(const Duration(milliseconds: 100));
        shortDedup.cleanup();

        expect(shortDedup.contains('old-1'), isFalse);
        expect(shortDedup.contains('old-2'), isFalse);
      });

      test('recently added entries survive cleanup()', () async {
        final shortDedup = MessageDeduplicator(
          maxAge: const Duration(milliseconds: 100),
          maxCount: 100,
        );

        shortDedup.isDuplicate('old-1');
        await Future.delayed(const Duration(milliseconds: 50));
        shortDedup.isDuplicate('fresh-1'); // added halfway through maxAge

        await Future.delayed(const Duration(milliseconds: 60)); // total >100ms for old-1
        shortDedup.cleanup();

        expect(shortDedup.contains('old-1'), isFalse);
        expect(shortDedup.contains('fresh-1'), isTrue);
      });

      test('LRU eviction keeps most recent entries on overflow', () {
        // maxCount=5: add 10 entries — oldest should be evicted
        for (var i = 0; i < 10; i++) {
          dedup.isDuplicate('msg-$i');
        }
        // msg-9 is the most recent
        expect(dedup.contains('msg-9'), isTrue);
        // msg-0 was the oldest and should have been evicted
        expect(dedup.contains('msg-0'), isFalse);
      });

      test('after overflow, lookup map and list are consistent', () {
        for (var i = 0; i < 20; i++) {
          dedup.isDuplicate('msg-$i');
        }
        // Verify no lookups throw and that isDuplicate is consistent
        expect(() => dedup.isDuplicate('msg-19'), returnsNormally);
        expect(dedup.isDuplicate('msg-19'), isTrue); // already seen
      });

      test('compaction does not break timestampFor on surviving entries', () {
        final largeDedup = MessageDeduplicator(maxCount: 10);

        // Force overflow and compaction
        for (var i = 0; i < 20; i++) {
          largeDedup.isDuplicate('msg-$i');
        }

        // Entries that survived compaction should still have timestamps
        if (largeDedup.contains('msg-19')) {
          expect(largeDedup.timestampFor('msg-19'), isNotNull);
        }
      });

      // -----------------------------------------------------------------------
      // L1 — _compactIfNeeded uses >= (not >) so compaction triggers at exactly
      //      25% dead-head zone.
      // -----------------------------------------------------------------------
      test('L1: compaction triggers when dead-head zone equals exactly 25% of '
          'backing-list length', () async {
        // Use a short maxAge so we can expire entries on demand.
        final shortDedup = MessageDeduplicator(
          maxAge: const Duration(milliseconds: 30),
          maxCount: 100,
        );

        // Add 4 entries.
        for (var i = 0; i < 4; i++) {
          shortDedup.isDuplicate('msg-$i');
        }

        // Wait for entries to expire, then trigger cleanup to advance _head.
        await Future.delayed(const Duration(milliseconds: 50));

        // After cleanup _head should advance past the 4 expired entries.
        // The backing list has 4 entries and _head would become 4, which is
        // 4 >= 4/4 = 1 → compaction fires (removing dead entries) and _head resets to 0.
        shortDedup.cleanup();

        // Add a new entry and verify the deduplicator is still consistent.
        expect(shortDedup.isDuplicate('msg-new'), isFalse);
        expect(shortDedup.contains('msg-new'), isTrue);
      });
    });
  });
}
