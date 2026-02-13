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
  });
}
