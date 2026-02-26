import 'dart:convert';
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
    // MED-N3: Store as base64 (consistent with KeyStorage) — smaller than hex
    // and fewer intermediate string objects in GC heap.
    final keyB64 = base64Encode(groupKey);
    final saltB64 = base64Encode(salt);
    await _storage.write(key: _groupKeyTag, value: keyB64);
    await _storage.write(key: _groupIdTag, value: groupId);
    await _storage.write(key: _nameTag, value: name);
    await _storage.write(
      key: _createdAtTag,
      value: createdAt.toIso8601String(),
    );
    await _storage.write(key: _saltTag, value: saltB64);
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
    final keyStr = await _storage.read(key: _groupKeyTag);
    final groupId = await _storage.read(key: _groupIdTag);
    final name = await _storage.read(key: _nameTag);
    final createdAtStr = await _storage.read(key: _createdAtTag);
    final saltStr = await _storage.read(key: _saltTag);

    if (keyStr == null ||
        groupId == null ||
        name == null ||
        createdAtStr == null ||
        saltStr == null) {
      return null;
    }

    final groupKey = _decodeBytes(keyStr);
    final salt = _decodeBytes(saltStr);

    // M11: If decoding fails (corrupt data), return null rather than crashing.
    if (groupKey == null || salt == null) return null;

    return (
      groupKey: groupKey,
      groupId: groupId,
      name: name,
      // C7: Use tryParse to avoid an uncaught FormatException on corrupt data.
      createdAt: DateTime.tryParse(createdAtStr) ?? DateTime.now(),
      salt: salt,
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

  /// Decode bytes from either base64 (current format) or legacy hex.
  ///
  /// MED-N3: Provides backward compatibility with devices that stored keys
  /// as hex before the migration to base64.
  static Uint8List? _decodeBytes(String s) {
    // A pure hex string contains only [0-9a-fA-F] and has even length.
    if (s.isNotEmpty && s.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) {
      return Uint8List.fromList(
        List.generate(
          s.length ~/ 2,
          (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
    }
    // M11: Wrap base64Decode in try/on to avoid uncaught FormatException on
    // corrupt storage values.
    try {
      return base64Decode(s);
    } on FormatException {
      return null;
    }
  }
}
