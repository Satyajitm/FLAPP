/// Thread-safe deduplicator with LRU eviction and time-based expiry.
///
/// Ported from Bitchat's MessageDeduplicator.
/// Used for both message ID deduplication (network layer) and
/// content key deduplication (UI layer).
class MessageDeduplicator {
  final Duration maxAge;
  final int maxCount;

  final List<_Entry> _entries = [];
  int _head = 0;
  final Map<String, DateTime> _lookup = {};

  MessageDeduplicator({
    this.maxAge = const Duration(seconds: 300),
    this.maxCount = 1024,
  });

  /// Check if message is duplicate and add if not.
  ///
  /// Returns `true` if the message was already seen, `false` otherwise.
  bool isDuplicate(String id) {
    final now = DateTime.now();
    _cleanupOldEntries(now.subtract(maxAge));

    if (_lookup.containsKey(id)) {
      return true;
    }

    _entries.add(_Entry(id: id, timestamp: now));
    _lookup[id] = now;
    _trimIfNeeded();

    return false;
  }

  /// Record an ID with a specific timestamp (for content key tracking).
  void record(String id, DateTime timestamp) {
    if (!_lookup.containsKey(id)) {
      _entries.add(_Entry(id: id, timestamp: timestamp));
      _lookup[id] = timestamp;
    }
    _trimIfNeeded();
  }

  /// Add an ID without checking (for announce-back tracking).
  void markProcessed(String id) {
    if (!_lookup.containsKey(id)) {
      final now = DateTime.now();
      _entries.add(_Entry(id: id, timestamp: now));
      _lookup[id] = now;
    }
  }

  /// Check if ID exists without adding.
  bool contains(String id) => _lookup.containsKey(id);

  /// Get timestamp for an ID.
  DateTime? timestampFor(String id) => _lookup[id];

  /// Clear all entries.
  void reset() {
    _entries.clear();
    _head = 0;
    _lookup.clear();
  }

  /// Periodic cleanup of expired entries and memory optimization.
  void cleanup() {
    _cleanupOldEntries(DateTime.now().subtract(maxAge));

    // Shrink if significantly oversized
    // (Dart lists don't expose capacity, but removing entries helps GC)
  }

  void _trimIfNeeded() {
    final activeCount = _entries.length - _head;
    if (activeCount <= maxCount) return;

    // Remove down to 75% of maxCount for better amortization
    final targetCount = (maxCount * 3) ~/ 4;
    final removeCount = activeCount - targetCount;

    for (var i = _head; i < _head + removeCount; i++) {
      _lookup.remove(_entries[i].id);
    }
    _head += removeCount;

    // Compact when head exceeds 25% of the list (smaller, more frequent GC batches)
    if (_head > _entries.length ~/ 4) {
      _entries.removeRange(0, _head);
      _head = 0;
    }
  }

  void _cleanupOldEntries(DateTime cutoff) {
    while (_head < _entries.length && _entries[_head].timestamp.isBefore(cutoff)) {
      _lookup.remove(_entries[_head].id);
      _head++;
    }
    // Compact when head exceeds 25% of the list (consistent with _trimIfNeeded)
    if (_head > 0 && _head > _entries.length ~/ 4) {
      _entries.removeRange(0, _head);
      _head = 0;
    }
  }
}

class _Entry {
  final String id;
  final DateTime timestamp;

  _Entry({required this.id, required this.timestamp});
}
