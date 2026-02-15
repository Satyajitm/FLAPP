import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../location/location_providers.dart';
import 'emergency_controller.dart';
import 'emergency_providers.dart';

/// SOS trigger UI.
class EmergencyScreen extends ConsumerStatefulWidget {
  const EmergencyScreen({super.key});

  @override
  ConsumerState<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends ConsumerState<EmergencyScreen> {
  bool _isConfirming = false;

  Future<void> _sendSos(EmergencyAlertType type) async {
    setState(() => _isConfirming = false);
    final locationState = ref.read(locationControllerProvider);
    final lat = locationState.myLocation?.latitude ?? 0.0;
    final lng = locationState.myLocation?.longitude ?? 0.0;
    await ref.read(emergencyControllerProvider.notifier).sendAlert(
      type: type,
      latitude: lat,
      longitude: lng,
      message: lat == 0.0 && lng == 0.0 ? 'Location unavailable' : '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final emergencyState = ref.watch(emergencyControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency'),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            if (emergencyState.isSending)
              const CircularProgressIndicator()
            else if (!_isConfirming)
              _buildSOSButton()
            else
              _buildConfirmation(),
            const SizedBox(height: 32),
            _buildAlertTypeGrid(),
            const Spacer(),
            if (emergencyState.alerts.isNotEmpty)
              _buildRecentAlerts(emergencyState.alerts),
          ],
        ),
      ),
    );
  }

  Widget _buildSOSButton() {
    return GestureDetector(
      onLongPress: () {
        setState(() => _isConfirming = true);
      },
      child: Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.red,
          boxShadow: [
            BoxShadow(
              color: Colors.red.withValues(alpha: 0.4),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sos, size: 48, color: Colors.white),
              SizedBox(height: 8),
              Text(
                'HOLD FOR SOS',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmation() {
    return Column(
      children: [
        const Text(
          'Send SOS Alert?',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'This will alert all nearby Fluxon users\nwith your location.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton(
              onPressed: () => setState(() => _isConfirming = false),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _sendSos(EmergencyAlertType.sos),
              child: const Text('SEND SOS'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAlertTypeGrid() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _alertTypeChip(Icons.personal_injury, 'Medical', Colors.orange),
        _alertTypeChip(Icons.person_search, 'Lost', Colors.blue),
        _alertTypeChip(Icons.warning, 'Danger', Colors.amber),
      ],
    );
  }

  Widget _alertTypeChip(IconData icon, String label, Color color) {
    return Column(
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.2),
          radius: 28,
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _buildRecentAlerts(List<EmergencyAlert> alerts) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Recent Alerts',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: alerts.length,
              itemBuilder: (context, index) {
                final alert = alerts[alerts.length - 1 - index];
                return ListTile(
                  leading: Icon(
                    Icons.warning,
                    color: alert.isLocal ? Colors.red : Colors.orange,
                  ),
                  title: Text(alert.type.name.toUpperCase()),
                  subtitle: Text(
                    alert.isLocal ? 'Sent by you' : 'From nearby peer',
                  ),
                  trailing: Text(
                    '${alert.timestamp.hour}:${alert.timestamp.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
