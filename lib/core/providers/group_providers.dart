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

/// Reactive provider that tracks the currently active [FluxonGroup].
///
/// [GroupManager] is a plain Dart class — mutations to its internal state
/// don't trigger Riverpod rebuilds. This [StateProvider] bridges that gap:
/// update it whenever the group changes (create, join, leave) so the UI
/// rebuilds reactively.
final activeGroupProvider = StateProvider<FluxonGroup?>((ref) {
  final gm = ref.read(groupManagerProvider);
  return gm.activeGroup;
});
