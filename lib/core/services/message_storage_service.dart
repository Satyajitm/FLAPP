import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../features/chat/message_model.dart';

/// Persists chat messages to per-group JSON files in the app's documents
/// directory.
///
/// Each group gets its own file: `messages_{groupId}.json`. This ensures
/// switching groups shows only the messages for that group, and old group
/// history is preserved independently.
///
/// The full list is written on each save — acceptable for a BLE mesh chat
/// where message volume is naturally low (no internet-scale traffic).
class MessageStorageService {
  /// Cached directory path to avoid repeated lookups.
  String? _cachedDirPath;

  /// Pending writes: groupId → latest message list. Flushed every 5 seconds
  /// or when the batch reaches 10 unsaved messages, whichever comes first.
  final Map<String, List<ChatMessage>> _pendingWrites = {};
  int _pendingSinceLastFlush = 0;
  Timer? _debounceTimer;

  static const _debounceInterval = Duration(seconds: 5);
  static const _batchSize = 10;

  /// Resolve the storage directory path (cached after first call).
  ///
  /// Visible for testing — subclasses can override to point at a temp
  /// directory.
  Future<String> getDirectoryPath() async {
    if (_cachedDirPath != null) return _cachedDirPath!;
    final dir = await getApplicationDocumentsDirectory();
    _cachedDirPath = dir.path;
    return _cachedDirPath!;
  }

  /// Resolve the file for a specific group.
  Future<File> getFileForGroup(String groupId) async {
    final dirPath = await getDirectoryPath();
    // Sanitize groupId to be filesystem-safe (hex strings are already safe,
    // but guard against edge cases).
    final safeId = groupId.replaceAll(RegExp(r'[^\w\-]'), '_');
    return File('$dirPath${Platform.pathSeparator}messages_$safeId.json');
  }

  /// Load all persisted messages for a specific group.
  ///
  /// Returns an empty list if the file does not exist or is malformed.
  /// Flushes any pending debounced write for this group first.
  Future<List<ChatMessage>> loadMessages(String groupId) async {
    // Flush only the pending write for this group, not all pending groups.
    if (_pendingWrites.containsKey(groupId)) {
      final messages = _pendingWrites.remove(groupId)!;
      // Only reset the counter if the map is now empty to keep batch semantics
      // correct for other groups that are still accumulating.
      if (_pendingWrites.isEmpty) {
        _pendingSinceLastFlush = 0;
        _debounceTimer?.cancel();
        _debounceTimer = null;
      }
      final file = await getFileForGroup(groupId);
      final jsonList = messages.map((m) => m.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList), flush: true);
    }
    try {
      final file = await getFileForGroup(groupId);
      if (!await file.exists()) return [];

      final contents = await file.readAsString();
      if (contents.trim().isEmpty) return [];

      final List<dynamic> jsonList = jsonDecode(contents) as List<dynamic>;
      return jsonList
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt or unreadable file — start fresh.
      return [];
    }
  }

  /// Persist the full message list for a group to disk.
  ///
  /// Writes are batched: the actual disk write is deferred by up to 5 seconds
  /// or until 10 unsaved messages have accumulated, whichever comes first.
  /// Call [flush] to write immediately (e.g. on app suspend).
  Future<void> saveMessages(String groupId, List<ChatMessage> messages) async {
    _pendingWrites[groupId] = messages;
    _pendingSinceLastFlush++;

    if (_pendingSinceLastFlush >= _batchSize) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      await _flushPendingWrites();
    } else {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceInterval, () {
        _flushPendingWrites();
      });
    }
  }

  /// Immediately flush all pending writes to disk.
  Future<void> flush() => _flushPendingWrites();

  Future<void> _flushPendingWrites() async {
    if (_pendingWrites.isEmpty) return;
    final writes = Map.of(_pendingWrites);
    _pendingWrites.clear();
    _pendingSinceLastFlush = 0;
    for (final entry in writes.entries) {
      final file = await getFileForGroup(entry.key);
      final jsonList = entry.value.map((m) => m.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList), flush: true);
    }
  }

  /// Delete a single message by its [id] and re-save.
  Future<void> deleteMessage(
    String groupId,
    String id,
    List<ChatMessage> messages,
  ) async {
    final filtered = messages.where((m) => m.id != id).toList();
    await saveMessages(groupId, filtered);
  }

  /// Cancel the debounce timer and synchronously flush any pending writes.
  ///
  /// Call this from [Provider.onDispose] to avoid losing messages on
  /// provider disposal (e.g. group change or app shutdown).
  Future<void> dispose() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _flushPendingWrites();
  }

  /// Delete all persisted messages for a group (removes the file).
  Future<void> deleteAllMessages(String groupId) async {
    _pendingWrites.remove(groupId); // Discard any queued write for this group.
    final file = await getFileForGroup(groupId);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
