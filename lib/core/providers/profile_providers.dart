import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../identity/user_profile_manager.dart';

/// Provides the [UserProfileManager] instance.
///
/// Must be overridden in main.dart after [UserProfileManager.initialize()].
final userProfileManagerProvider = Provider<UserProfileManager>((ref) {
  throw UnimplementedError(
    'userProfileManagerProvider must be overridden with the initialized '
    'UserProfileManager before use.',
  );
});

/// Reactive display name provider. Initial value is loaded from secure storage
/// and overridden in main.dart. Updates reactively when the user changes their
/// name (e.g. via the group menu dialog).
///
/// Must be overridden in main.dart after [UserProfileManager.initialize()].
final displayNameProvider = StateProvider<String>((ref) {
  throw UnimplementedError(
    'displayNameProvider must be overridden with the loaded display name '
    'after UserProfileManager initialization.',
  );
});
