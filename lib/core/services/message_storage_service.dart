import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sodium_libs/sodium_libs.dart';
import '../crypto/sodium_instance.dart';
import '../../features/chat/message_model.dart';

/// Persists chat messages to per-group JSON files in the app's documents
/// directory, encrypted at rest with a per-device file encryption key.
///
/// C5: Messages are encrypted with ChaCha20-Poly1305 (via libsodium AEAD)
/// using a random 32-byte key stored in flutter_secure_storage (Android
/// Keystore / iOS Keychain backed). This protects message history on
/// rooted/jailbroken devices and from backup extraction.
///
/// Each group gets its own file: `messages_{groupId}.bin`. This ensures
/// switching groups shows only the messages for that group, and old group
/// history is preserved independently.
class MessageStorageService {
  static const _secureStorage = FlutterSecureStorage();
  static const _fileKeyStorageKey = 'message_file_enc_key';

  /// Cached file encryption key (lazy-loaded from flutter_secure_storage).
  Uint8List? _fileEncryptionKey;

  /// Cached directory path to avoid repeated lookups.
  String? _cachedDirPath;

  /// Pending writes: groupId → latest message list. Flushed every 5 seconds
  /// or when the batch reaches 10 unsaved messages, whichever comes first.
  final Map<String, List<ChatMessage>> _pendingWrites = {};
  int _pendingSinceLastFlush = 0;
  Timer? _debounceTimer;

  static const _debounceInterval = Duration(seconds: 5);
  static const _batchSize = 10;

  /// Load or generate the file encryption key from secure storage.
  Future<Uint8List> _getFileKey() async {
    if (_fileEncryptionKey != null) return _fileEncryptionKey!;

    final stored = await _secureStorage.read(key: _fileKeyStorageKey);
    if (stored != null) {
      // Decode stored hex key.
      final bytes = Uint8List(stored.length ~/ 2);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = int.parse(stored.substring(i * 2, i * 2 + 2), radix: 16);
      }
      _fileEncryptionKey = bytes;
    } else {
      // Generate a new random 32-byte file encryption key.
      final sodium = sodiumInstance;
      final key = sodium.randombytes.buf(sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes);
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await _secureStorage.write(key: _fileKeyStorageKey, value: hex);
      _fileEncryptionKey = key;
    }

    return _fileEncryptionKey!;
  }

  /// Encrypt [data] with the file encryption key (ChaCha20-Poly1305).
  ///
  /// Returns nonce prepended to ciphertext. Override in tests to bypass
  /// encryption (avoids sodium native-binary requirement on host tests).
  Future<Uint8List> encryptData(Uint8List data) async {
    final sodium = sodiumInstance;
    final key = await _getFileKey();
    final nonce = sodium.randombytes.buf(sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes);
    final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: data,
      nonce: nonce,
      key: SecureKey.fromList(sodium, key),
    );
    final result = Uint8List(nonce.length + ciphertext.length);
    result.setAll(0, nonce);
    result.setAll(nonce.length, ciphertext);
    return result;
  }

  /// Decrypt [data] with the file encryption key. Returns null on failure.
  ///
  /// Override in tests to bypass encryption.
  Future<Uint8List?> decryptData(Uint8List data) async {
    final sodium = sodiumInstance;
    final key = await _getFileKey();
    final nonceLen = sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes;
    if (data.length < nonceLen) return null;
    final nonce = Uint8List.sublistView(data, 0, nonceLen);
    final ciphertext = Uint8List.sublistView(data, nonceLen);
    try {
      return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: SecureKey.fromList(sodium, key),
      );
    } catch (_) {
      return null;
    }
  }

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
    return File('$dirPath${Platform.pathSeparator}messages_$safeId.bin');
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
      await _writeEncrypted(groupId, messages);
    }
    try {
      final file = await getFileForGroup(groupId);
      if (!await file.exists()) return [];

      final fileBytes = await file.readAsBytes();
      if (fileBytes.isEmpty) return [];

      // Attempt decryption first (normal path).
      final decrypted = await decryptData(fileBytes);
      if (decrypted != null) {
        final contents = utf8.decode(decrypted);
        if (contents.trim().isEmpty) return [];
        final List<dynamic> jsonList = jsonDecode(contents) as List<dynamic>;
        return jsonList
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      // Migration path: try reading as legacy plaintext JSON.
      // This handles the one-time upgrade from unencrypted to encrypted storage.
      try {
        final contents = utf8.decode(fileBytes);
        if (contents.trim().isEmpty) return [];
        final List<dynamic> jsonList = jsonDecode(contents) as List<dynamic>;
        final messages = jsonList
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        // Re-save with encryption so legacy files are migrated transparently.
        await _writeEncrypted(groupId, messages);
        return messages;
      } catch (_) {
        return [];
      }
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
      await _writeEncrypted(entry.key, entry.value);
    }
  }

  /// Encrypt and write [messages] for [groupId] to disk.
  Future<void> _writeEncrypted(String groupId, List<ChatMessage> messages) async {
    final file = await getFileForGroup(groupId);
    final jsonList = messages.map((m) => m.toJson()).toList();
    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(jsonList)));
    final encrypted = await encryptData(plaintext);
    await file.writeAsBytes(encrypted, flush: true);
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
