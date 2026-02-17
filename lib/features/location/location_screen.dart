import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'location_providers.dart';

/// Map view showing group members' locations.
class LocationScreen extends ConsumerStatefulWidget {
  const LocationScreen({super.key});

  @override
  ConsumerState<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends ConsumerState<LocationScreen> {
  final _mapController = MapController();

  /// Disk-cached tile provider. Null until [_initTileCache] completes —
  /// flutter_map falls back to NetworkTileProvider while null.
  CachedTileProvider? _tileProvider;

  @override
  void initState() {
    super.initState();
    _initTileCache();
  }

  Future<void> _initTileCache() async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final tileCachePath =
          '${cacheDir.path}${Platform.pathSeparator}osm_tiles';
      await Directory(tileCachePath).create(recursive: true);
      final store = FileCacheStore(tileCachePath);
      if (mounted) {
        setState(() {
          _tileProvider = CachedTileProvider(
            maxStale: const Duration(days: 7),
            store: store,
          );
        });
      }
    } catch (_) {
      // Silent fallback to NetworkTileProvider if cache init fails
      // (e.g. storage permission denied or unavailable).
    }
  }

  @override
  Widget build(BuildContext context) {
    final locationState = ref.watch(locationControllerProvider);
    final isBroadcasting = locationState.isBroadcasting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Group Map'),
        actions: [
          IconButton(
            icon: Icon(
              isBroadcasting ? Icons.location_on : Icons.location_off,
            ),
            onPressed: () {
              final controller = ref.read(locationControllerProvider.notifier);
              if (isBroadcasting) {
                controller.stopBroadcasting();
              } else {
                controller.startBroadcasting();
              }
            },
          ),
        ],
      ),
      body: FlutterMap(
        mapController: _mapController,
        options: const MapOptions(
          initialCenter: LatLng(0, 0),
          initialZoom: 15,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.fluxonlink.fluxon_app',
            tileProvider: _tileProvider,
          ),
          MarkerLayer(
            markers: _buildMarkers(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _centerOnMe,
        child: const Icon(Icons.my_location),
      ),
    );
  }

  List<Marker> _buildMarkers() {
    final memberLocations = ref.watch(locationControllerProvider).memberLocations;
    return memberLocations.values.map((loc) {
      return Marker(
        point: LatLng(loc.latitude, loc.longitude),
        width: 40,
        height: 40,
        child: const Icon(
          Icons.person_pin_circle,
          color: Colors.blue,
          size: 40,
        ),
      );
    }).toList();
  }

  void _centerOnMe() {
    final myLoc = ref.read(locationControllerProvider).myLocation;
    if (myLoc != null) {
      _mapController.move(LatLng(myLoc.latitude, myLoc.longitude), 15);
    }
  }
}
