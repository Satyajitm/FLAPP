import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for group membership data.
///
/// Mirrors the [KeyStorage] pattern in `keys.dart`. Only the passphrase,
/// group name, and creation timestamp are persisted — the group ID and
/// symmetric key are deterministically re-derived from the passphrase
/// via [GroupCipher] on each restore.
class GroupStorage {
  static const _passphraseTag = 'fluxon_group_passphrase';
  static const _nameTag = 'fluxon_group_name';
  static const _createdAtTag = 'fluxon_group_created_at';

  final FlutterSecureStorage _storage;

  GroupStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Persist the active group's recoverable data.
  Future<void> saveGroup({
    required String passphrase,
    required String name,
    required DateTime createdAt,
  }) async {
    await _storage.write(key: _passphraseTag, value: passphrase);
    await _storage.write(key: _nameTag, value: name);
    await _storage.write(
      key: _createdAtTag,
      value: createdAt.toIso8601String(),
    );
  }

  /// Load a previously saved group, or null if none exists.
  Future<({String passphrase, String name, DateTime createdAt})?> loadGroup() async {
    final passphrase = await _storage.read(key: _passphraseTag);
    final name = await _storage.read(key: _nameTag);
    final createdAtStr = await _storage.read(key: _createdAtTag);

    if (passphrase == null || name == null || createdAtStr == null) return null;

    return (
      passphrase: passphrase,
      name: name,
      createdAt: DateTime.parse(createdAtStr),
    );
  }

  /// Delete all persisted group data.
  Future<void> deleteGroup() async {
    await _storage.delete(key: _passphraseTag);
    await _storage.delete(key: _nameTag);
    await _storage.delete(key: _createdAtTag);
  }
}
