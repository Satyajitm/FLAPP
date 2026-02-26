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

  /// Save a new display name. Trims whitespace and removes control/RTL characters.
  /// Passing an empty string clears the stored name.
  Future<void> setName(String name) async {
    // Strip C0 control chars, zero-width chars, and Unicode bidirectional
    // override characters that could alter rendering in the UI (LOW finding).
    final sanitized = name.replaceAll(
        RegExp(r'[\x00-\x1F\u200B-\u200F\u202A-\u202E\u2066-\u2069]'), '');
    final trimmed = sanitized.trim();
    // Enforce max display name length of 32 characters.
    _displayName = trimmed.length > 32 ? trimmed.substring(0, 32) : trimmed;
    if (_displayName.isEmpty) {
      await _storage.delete(key: _nameKey);
    } else {
      await _storage.write(key: _nameKey, value: _displayName);
    }
  }
}
