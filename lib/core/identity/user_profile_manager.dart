import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages the user's local display name, persisted across sessions.
class UserProfileManager {
  static const _nameKey = 'user_display_name';

  final FlutterSecureStorage _storage;
  String _displayName = '';

  UserProfileManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// The user's current display name. Empty string if not yet set.
  String get displayName => _displayName;

  /// Whether the user has chosen a display name.
  bool get hasName => _displayName.isNotEmpty;

  /// Load the persisted display name from secure storage.
  Future<void> initialize() async {
    _displayName = await _storage.read(key: _nameKey) ?? '';
  }

  /// Save a new display name. Trims whitespace.
  /// Passing an empty string clears the stored name.
  Future<void> setName(String name) async {
    _displayName = name.trim();
    if (_displayName.isEmpty) {
      await _storage.delete(key: _nameKey);
    } else {
      await _storage.write(key: _nameKey, value: _displayName);
    }
  }
}
