import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../identity/group_manager.dart';

/// Provides the [GroupManager] instance.
///
/// Override this after identity initialization in main.dart.
final groupManagerProvider = Provider<GroupManager>((ref) {
  throw UnimplementedError(
    'groupManagerProvider must be overridden with a GroupManager '
    'instance after initialization.',
  );
});
