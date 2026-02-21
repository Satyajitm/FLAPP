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
  Future<List<ChatMessage>> loadMessages(String groupId) async {
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
  Future<void> saveMessages(String groupId, List<ChatMessage> messages) async {
    final file = await getFileForGroup(groupId);
    final jsonList = messages.map((m) => m.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonList), flush: true);
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

  /// Delete all persisted messages for a group (removes the file).
  Future<void> deleteAllMessages(String groupId) async {
    final file = await getFileForGroup(groupId);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
