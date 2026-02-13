import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'location_model.dart';

/// Map view showing group members' locations.
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final _mapController = MapController();

  // TODO: Wire up to LocationController via Riverpod
  final Map<String, LocationUpdate> _memberLocations = {};
  bool _isBroadcasting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Group Map'),
        actions: [
          IconButton(
            icon: Icon(
              _isBroadcasting ? Icons.location_on : Icons.location_off,
            ),
            onPressed: () {
              setState(() => _isBroadcasting = !_isBroadcasting);
              // TODO: Toggle location broadcasting
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
    return _memberLocations.values.map((loc) {
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
    // TODO: Center map on local device's location
  }
}
