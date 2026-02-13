import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import 'data/emergency_repository.dart';

/// Emergency alert types.
enum EmergencyAlertType {
  sos(0),
  lostPerson(1),
  medical(2),
  danger(3);

  const EmergencyAlertType(this.value);
  final int value;
}

/// Emergency alert state.
class EmergencyState {
  final List<EmergencyAlert> alerts;
  final bool isSending;

  const EmergencyState({
    this.alerts = const [],
    this.isSending = false,
  });

  EmergencyState copyWith({
    List<EmergencyAlert>? alerts,
    bool? isSending,
  }) {
    return EmergencyState(
      alerts: alerts ?? this.alerts,
      isSending: isSending ?? this.isSending,
    );
  }
}

/// An emergency alert received from the mesh.
class EmergencyAlert {
  final PeerId sender;
  final EmergencyAlertType type;
  final double latitude;
  final double longitude;
  final String message;
  final DateTime timestamp;
  final bool isLocal;

  EmergencyAlert({
    required this.sender,
    required this.type,
    required this.latitude,
    required this.longitude,
    this.message = '',
    DateTime? timestamp,
    this.isLocal = false,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Emergency alert broadcast logic.
///
/// Depends on [EmergencyRepository] (DIP) instead of Transport/BinaryProtocol
/// directly.
class EmergencyController extends StateNotifier<EmergencyState> {
  final EmergencyRepository _repository;
  final PeerId _myPeerId;
  StreamSubscription? _alertSub;

  EmergencyController({
    required EmergencyRepository repository,
    required PeerId myPeerId,
  })  : _repository = repository,
        _myPeerId = myPeerId,
        super(const EmergencyState()) {
    _listenForAlerts();
  }

  void _listenForAlerts() {
    _alertSub = _repository.onAlertReceived.listen((alert) {
      state = state.copyWith(alerts: [...state.alerts, alert]);
    });
  }

  /// Send an SOS emergency alert.
  Future<void> sendAlert({
    required EmergencyAlertType type,
    required double latitude,
    required double longitude,
    String message = '',
  }) async {
    state = state.copyWith(isSending: true);

    try {
      await _repository.sendAlert(
        type: type,
        latitude: latitude,
        longitude: longitude,
        message: message,
      );

      final alert = EmergencyAlert(
        sender: _myPeerId,
        type: type,
        latitude: latitude,
        longitude: longitude,
        message: message,
        isLocal: true,
      );

      state = state.copyWith(
        alerts: [...state.alerts, alert],
        isSending: false,
      );
    } catch (_) {
      state = state.copyWith(isSending: false);
    }
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }
}
