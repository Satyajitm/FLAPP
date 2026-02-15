import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/group_providers.dart';
import '../chat/chat_providers.dart';
import 'data/emergency_repository.dart';
import 'data/mesh_emergency_repository.dart';
import 'emergency_controller.dart';

// ---------------------------------------------------------------------------
// Emergency feature providers
// ---------------------------------------------------------------------------

/// Provides the [EmergencyRepository] implementation.
final emergencyRepositoryProvider = Provider<EmergencyRepository>((ref) {
  final transport = ref.watch(transportProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  final config = ref.watch(transportConfigProvider);
  final groupManager = ref.watch(groupManagerProvider);
  final repository = MeshEmergencyRepository(
    transport: transport,
    myPeerId: myPeerId,
    config: config,
    groupManager: groupManager,
  );
  ref.onDispose(() => repository.dispose());
  return repository;
});

/// Provides the [EmergencyController] StateNotifier.
final emergencyControllerProvider =
    StateNotifierProvider<EmergencyController, EmergencyState>((ref) {
  final repository = ref.watch(emergencyRepositoryProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  return EmergencyController(
    repository: repository,
    myPeerId: myPeerId,
  );
});
