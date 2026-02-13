import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/device/device_services.dart';
import '../../core/providers/group_providers.dart';
import '../chat/chat_providers.dart';
import 'data/location_repository.dart';
import 'data/mesh_location_repository.dart';
import 'location_controller.dart';

// ---------------------------------------------------------------------------
// Device service providers
// ---------------------------------------------------------------------------

/// Provides the [GpsService] implementation.
///
/// Override this in tests to supply a mock.
final gpsServiceProvider = Provider<GpsService>((ref) {
  return GeolocatorGpsService();
});

/// Provides the [PermissionService] implementation.
///
/// Override this in tests to supply a mock.
final permissionServiceProvider = Provider<PermissionService>((ref) {
  return GeolocatorPermissionService();
});

// ---------------------------------------------------------------------------
// Location feature providers
// ---------------------------------------------------------------------------

/// Provides the [LocationRepository] implementation.
final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  final transport = ref.watch(transportProvider);
  final groupManager = ref.watch(groupManagerProvider);
  final gpsService = ref.watch(gpsServiceProvider);
  final permissionService = ref.watch(permissionServiceProvider);
  final repository = MeshLocationRepository(
    transport: transport,
    groupManager: groupManager,
    gpsService: gpsService,
    permissionService: permissionService,
  );
  ref.onDispose(() => repository.dispose());
  return repository;
});

/// Provides the [LocationController] StateNotifier.
final locationControllerProvider =
    StateNotifierProvider<LocationController, LocationState>((ref) {
  final repository = ref.watch(locationRepositoryProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  final config = ref.watch(transportConfigProvider);
  return LocationController(
    repository: repository,
    myPeerId: myPeerId,
    config: config,
  );
});
