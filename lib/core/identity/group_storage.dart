import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for group membership data.
///
/// Stores only the derived group key (hex-encoded) and group ID — never the
/// raw passphrase. The passphrase is used transiently at create/join time and
/// is not persisted.
class GroupStorage {
  static const _groupKeyTag = 'fluxon_group_key';
  static const _groupIdTag = 'fluxon_group_id';
  static const _nameTag = 'fluxon_group_name';
  static const _createdAtTag = 'fluxon_group_created_at';

  final FlutterSecureStorage _storage;

  GroupStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Persist the active group's recoverable data.
  ///
  /// Only the derived [groupKey] bytes and [groupId] string are stored —
  /// the raw passphrase is never written to storage.
  Future<void> saveGroup({
    required Uint8List groupKey,
    required String groupId,
    required String name,
    required DateTime createdAt,
  }) async {
    final keyHex = groupKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _groupKeyTag, value: keyHex);
    await _storage.write(key: _groupIdTag, value: groupId);
    await _storage.write(key: _nameTag, value: name);
    await _storage.write(
      key: _createdAtTag,
      value: createdAt.toIso8601String(),
    );
  }

  /// Load a previously saved group, or null if none exists.
  Future<({Uint8List groupKey, String groupId, String name, DateTime createdAt})?> loadGroup() async {
    final keyHex = await _storage.read(key: _groupKeyTag);
    final groupId = await _storage.read(key: _groupIdTag);
    final name = await _storage.read(key: _nameTag);
    final createdAtStr = await _storage.read(key: _createdAtTag);

    if (keyHex == null || groupId == null || name == null || createdAtStr == null) return null;

    // Decode hex key back to bytes
    final groupKey = Uint8List.fromList(
      List.generate(keyHex.length ~/ 2, (i) => int.parse(keyHex.substring(i * 2, i * 2 + 2), radix: 16)),
    );

    return (
      groupKey: groupKey,
      groupId: groupId,
      name: name,
      createdAt: DateTime.parse(createdAtStr),
    );
  }

  /// Delete all persisted group data.
  Future<void> deleteGroup() async {
    await _storage.delete(key: _groupKeyTag);
    await _storage.delete(key: _groupIdTag);
    await _storage.delete(key: _nameTag);
    await _storage.delete(key: _createdAtTag);
  }
}
