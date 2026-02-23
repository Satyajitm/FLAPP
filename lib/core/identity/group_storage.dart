import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for group membership data.
///
/// Stores only the derived group key (hex-encoded), group ID, salt (hex-encoded),
/// and group name — never the raw passphrase. The passphrase is used transiently
/// at create/join time and is not persisted.
class GroupStorage {
  static const _groupKeyTag = 'fluxon_group_key';
  static const _groupIdTag = 'fluxon_group_id';
  static const _nameTag = 'fluxon_group_name';
  static const _createdAtTag = 'fluxon_group_created_at';
  static const _saltTag = 'fluxon_group_salt';

  final FlutterSecureStorage _storage;

  GroupStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Persist the active group's recoverable data.
  ///
  /// Only the derived [groupKey] bytes, [groupId] string, and [salt] bytes
  /// are stored — the raw passphrase is never written to storage.
  Future<void> saveGroup({
    required Uint8List groupKey,
    required String groupId,
    required String name,
    required DateTime createdAt,
    required Uint8List salt,
  }) async {
    final keyHex = _toHex(groupKey);
    final saltHex = _toHex(salt);
    await _storage.write(key: _groupKeyTag, value: keyHex);
    await _storage.write(key: _groupIdTag, value: groupId);
    await _storage.write(key: _nameTag, value: name);
    await _storage.write(
      key: _createdAtTag,
      value: createdAt.toIso8601String(),
    );
    await _storage.write(key: _saltTag, value: saltHex);
  }

  /// Load a previously saved group, or null if none exists.
  Future<
      ({
        Uint8List groupKey,
        String groupId,
        String name,
        DateTime createdAt,
        Uint8List salt,
      })?> loadGroup() async {
    final keyHex = await _storage.read(key: _groupKeyTag);
    final groupId = await _storage.read(key: _groupIdTag);
    final name = await _storage.read(key: _nameTag);
    final createdAtStr = await _storage.read(key: _createdAtTag);
    final saltHex = await _storage.read(key: _saltTag);

    if (keyHex == null ||
        groupId == null ||
        name == null ||
        createdAtStr == null ||
        saltHex == null) {
      return null;
    }

    return (
      groupKey: _fromHex(keyHex),
      groupId: groupId,
      name: name,
      createdAt: DateTime.parse(createdAtStr),
      salt: _fromHex(saltHex),
    );
  }

  /// Delete all persisted group data.
  Future<void> deleteGroup() async {
    await _storage.delete(key: _groupKeyTag);
    await _storage.delete(key: _groupIdTag);
    await _storage.delete(key: _nameTag);
    await _storage.delete(key: _createdAtTag);
    await _storage.delete(key: _saltTag);
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static String _toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) => Uint8List.fromList(
        List.generate(
          hex.length ~/ 2,
          (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
}
