import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import '../../core/transport/transport_config.dart';
import 'data/location_repository.dart';
import 'location_model.dart';

/// Location state — tracks all group members' locations.
class LocationState {
  final Map<PeerId, LocationUpdate> memberLocations;
  final LocationUpdate? myLocation;
  final bool isBroadcasting;

  const LocationState({
    this.memberLocations = const {},
    this.myLocation,
    this.isBroadcasting = false,
  });

  LocationState copyWith({
    Map<PeerId, LocationUpdate>? memberLocations,
    LocationUpdate? myLocation,
    bool? isBroadcasting,
  }) {
    return LocationState(
      memberLocations: memberLocations ?? this.memberLocations,
      myLocation: myLocation ?? this.myLocation,
      isBroadcasting: isBroadcasting ?? this.isBroadcasting,
    );
  }
}

/// Location controller — manages location broadcasting and tracking.
///
/// All transport, protocol, encryption, and GPS details are delegated to the
/// injected [LocationRepository]. This controller is purely concerned with
/// application-level state management and periodic broadcasting logic.
class LocationController extends StateNotifier<LocationState> {
  final LocationRepository _repository;
  final PeerId _myPeerId;
  final TransportConfig _config;

  Timer? _broadcastTimer;
  StreamSubscription? _locationSub;

  LocationController({
    required LocationRepository repository,
    required PeerId myPeerId,
    TransportConfig config = TransportConfig.defaultConfig,
  })  : _repository = repository,
        _myPeerId = myPeerId,
        _config = config,
        super(const LocationState()) {
    _listenForLocationUpdates();
  }

  void _listenForLocationUpdates() {
    _locationSub = _repository.onLocationReceived.listen((update) {
      state = state.copyWith(
        memberLocations: {...state.memberLocations, update.peerId: update},
      );
    });
  }

  /// Start broadcasting our location periodically.
  Future<void> startBroadcasting() async {
    final hasPermission = await _repository.ensureLocationPermission();
    if (!hasPermission) return;

    state = state.copyWith(isBroadcasting: true);

    // Broadcast immediately, then periodically
    await _broadcastCurrentLocation();
    _broadcastTimer = Timer.periodic(
      Duration(seconds: _config.locationBroadcastIntervalSeconds),
      (_) => _broadcastCurrentLocation(),
    );
  }

  /// Stop broadcasting location.
  void stopBroadcasting() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    state = state.copyWith(isBroadcasting: false);
  }

  Future<void> _broadcastCurrentLocation() async {
    try {
      final myUpdate = await _repository.getCurrentLocation(_myPeerId);
      state = state.copyWith(myLocation: myUpdate);
      await _repository.broadcastLocation(myUpdate, _myPeerId);
    } catch (_) {
      // GPS not available; skip this broadcast
    }
  }

  @override
  void dispose() {
    _broadcastTimer?.cancel();
    _locationSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
