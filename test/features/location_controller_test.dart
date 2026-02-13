import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/transport/transport_config.dart';
import 'package:fluxon_app/features/location/data/location_repository.dart';
import 'package:fluxon_app/features/location/location_controller.dart';
import 'package:fluxon_app/features/location/location_model.dart';

// ---------------------------------------------------------------------------
// Fake LocationRepository for testing the Controller in isolation
// ---------------------------------------------------------------------------

class FakeLocationRepository implements LocationRepository {
  final StreamController<LocationUpdate> _locationController =
      StreamController<LocationUpdate>.broadcast();
  final List<LocationUpdate> broadcastedLocations = [];
  bool permissionGranted = true;
  bool shouldFailOnGetLocation = false;
  LocationUpdate? fakeCurrentLocation;

  @override
  Stream<LocationUpdate> get onLocationReceived => _locationController.stream;

  @override
  Future<LocationUpdate> getCurrentLocation(PeerId myPeerId) async {
    if (shouldFailOnGetLocation) {
      throw Exception('GPS unavailable');
    }
    return fakeCurrentLocation ??
        LocationUpdate(
          peerId: myPeerId,
          latitude: 37.7749,
          longitude: -122.4194,
          accuracy: 10.0,
        );
  }

  @override
  Future<void> broadcastLocation(
      LocationUpdate location, PeerId sender) async {
    broadcastedLocations.add(location);
  }

  @override
  Future<bool> ensureLocationPermission() async {
    return permissionGranted;
  }

  /// Simulate an incoming location update from a remote peer.
  void simulateIncoming(LocationUpdate update) {
    _locationController.add(update);
  }

  @override
  void dispose() {
    _locationController.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PeerId _makePeerId(int fillByte) =>
    PeerId(Uint8List(32)..fillRange(0, 32, fillByte));

LocationUpdate _makeRemoteLocation({
  int senderByte = 0xBB,
  double lat = 34.0,
  double lng = -118.0,
}) {
  return LocationUpdate(
    peerId: _makePeerId(senderByte),
    latitude: lat,
    longitude: lng,
    accuracy: 5.0,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('LocationController', () {
    late FakeLocationRepository repository;
    late LocationController controller;
    final myPeerId = _makePeerId(0xAA);

    setUp(() {
      repository = FakeLocationRepository();
      controller = LocationController(
        repository: repository,
        myPeerId: myPeerId,
        config: const TransportConfig(
          locationBroadcastIntervalSeconds: 60, // Long interval to avoid
        ),
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('initial state has no locations and is not broadcasting', () {
      expect(controller.state.memberLocations, isEmpty);
      expect(controller.state.myLocation, isNull);
      expect(controller.state.isBroadcasting, isFalse);
    });

    test('incoming location updates from repository are added to state',
        () async {
      final update = _makeRemoteLocation(senderByte: 0xCC, lat: 40.0);
      repository.simulateIncoming(update);

      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.memberLocations, hasLength(1));
      final stored =
          controller.state.memberLocations[_makePeerId(0xCC)];
      expect(stored, isNotNull);
      expect(stored!.latitude, equals(40.0));
    });

    test('multiple updates from same peer overwrite previous location',
        () async {
      repository.simulateIncoming(
        _makeRemoteLocation(senderByte: 0xDD, lat: 10.0),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      repository.simulateIncoming(
        _makeRemoteLocation(senderByte: 0xDD, lat: 20.0),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.memberLocations, hasLength(1));
      final stored =
          controller.state.memberLocations[_makePeerId(0xDD)];
      expect(stored!.latitude, equals(20.0));
    });

    test('updates from different peers accumulate', () async {
      repository.simulateIncoming(
        _makeRemoteLocation(senderByte: 0x01, lat: 10.0),
      );
      repository.simulateIncoming(
        _makeRemoteLocation(senderByte: 0x02, lat: 20.0),
      );
      repository.simulateIncoming(
        _makeRemoteLocation(senderByte: 0x03, lat: 30.0),
      );

      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.state.memberLocations, hasLength(3));
    });

    test('startBroadcasting sets isBroadcasting and broadcasts location',
        () async {
      await controller.startBroadcasting();

      expect(controller.state.isBroadcasting, isTrue);
      expect(controller.state.myLocation, isNotNull);
      expect(controller.state.myLocation!.latitude, equals(37.7749));
      expect(repository.broadcastedLocations, hasLength(1));
    });

    test('startBroadcasting does nothing if permission denied', () async {
      repository.permissionGranted = false;

      await controller.startBroadcasting();

      expect(controller.state.isBroadcasting, isFalse);
      expect(controller.state.myLocation, isNull);
      expect(repository.broadcastedLocations, isEmpty);
    });

    test('stopBroadcasting clears broadcasting state', () async {
      await controller.startBroadcasting();
      expect(controller.state.isBroadcasting, isTrue);

      controller.stopBroadcasting();
      expect(controller.state.isBroadcasting, isFalse);
    });

    test('broadcast gracefully handles GPS failure', () async {
      repository.shouldFailOnGetLocation = true;

      // Should not throw, just silently skip
      await controller.startBroadcasting();

      // isBroadcasting is true (the timer is set), but no location was
      // broadcast because GPS failed
      expect(controller.state.isBroadcasting, isTrue);
      expect(controller.state.myLocation, isNull);
      expect(repository.broadcastedLocations, isEmpty);
    });
  });
}
