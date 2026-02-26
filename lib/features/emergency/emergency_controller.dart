import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import '../../shared/logger.dart';
import 'data/emergency_repository.dart';

/// Emergency alert types.
enum EmergencyAlertType {
  sos(0),
  lostPerson(1),
  medical(2),
  danger(3);

  const EmergencyAlertType(this.value);
  final int value;

  /// O(1) lookup map built once at class load time.
  static final Map<int, EmergencyAlertType> _byValue = {
    for (final t in EmergencyAlertType.values) t.value: t,
  };

  static EmergencyAlertType? fromValue(int value) => _byValue[value];
}

/// Emergency alert state.
class EmergencyState {
  final List<EmergencyAlert> alerts;
  final bool isSending;

  /// True when the last send attempt failed. UI should show a retry button.
  final bool hasSendError;

  /// Number of retry attempts made so far (0 = not yet retried).
  final int retryCount;

  const EmergencyState({
    this.alerts = const [],
    this.isSending = false,
    this.hasSendError = false,
    this.retryCount = 0,
  });

  /// True if a retry is possible (failed and under the max retry limit).
  bool get canRetry => hasSendError && retryCount < EmergencyController.maxRetries;

  EmergencyState copyWith({
    List<EmergencyAlert>? alerts,
    bool? isSending,
    bool? hasSendError,
    int? retryCount,
  }) {
    return EmergencyState(
      alerts: alerts ?? this.alerts,
      isSending: isSending ?? this.isSending,
      hasSendError: hasSendError ?? this.hasSendError,
      retryCount: retryCount ?? this.retryCount,
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

/// Stores the parameters for a failed alert so it can be retried.
class _PendingAlert {
  final EmergencyAlertType type;
  final double latitude;
  final double longitude;
  final String message;

  const _PendingAlert({
    required this.type,
    required this.latitude,
    required this.longitude,
    required this.message,
  });
}

/// Emergency alert broadcast logic.
///
/// Depends on [EmergencyRepository] (DIP) instead of Transport/BinaryProtocol
/// directly.
class EmergencyController extends StateNotifier<EmergencyState> {
  final EmergencyRepository _repository;
  final PeerId _myPeerId;
  StreamSubscription? _alertSub;
  bool _isDisposed = false;

  /// Maximum number of manual retries allowed after the initial send attempt.
  static const maxRetries = 5;

  /// The last failed alert, retained for retry.
  _PendingAlert? _pendingAlert;

  EmergencyController({
    required EmergencyRepository repository,
    required PeerId myPeerId,
  })  : _repository = repository,
        _myPeerId = myPeerId,
        super(const EmergencyState()) {
    _listenForAlerts();
  }

  /// Maximum number of alerts retained in state to prevent unbounded memory growth.
  static const _maxAlerts = 200;

  void _listenForAlerts() {
    // H14: Add onError and cancelOnError: false to prevent unhandled stream errors.
    _alertSub = _repository.onAlertReceived.listen(
      (alert) {
        final updated = [...state.alerts, alert];
        state = state.copyWith(
          alerts: updated.length > _maxAlerts
              ? updated.sublist(updated.length - _maxAlerts)
              : updated,
        );
      },
      onError: (Object e) {
        SecureLogger.warning('EmergencyController: alert stream error: $e');
      },
      cancelOnError: false,
    );
  }

  /// Send an SOS emergency alert.
  ///
  /// On failure, sets [EmergencyState.hasSendError] = true so the UI can
  /// show a retry button. Call [retryAlert] to retry with exponential backoff.
  Future<void> sendAlert({
    required EmergencyAlertType type,
    required double latitude,
    required double longitude,
    String message = '',
  }) async {
    // Drop concurrent send attempts — prevents _pendingAlert clobber and
    // interleaved rebroadcast loops.
    if (state.isSending) return;

    _pendingAlert = _PendingAlert(
      type: type,
      latitude: latitude,
      longitude: longitude,
      message: message,
    );
    state = state.copyWith(isSending: true, hasSendError: false, retryCount: 0);
    await _doSend();
  }

  /// Retry the last failed alert (called by the UI retry button).
  ///
  /// Each call applies an exponential backoff delay: 500 ms × 2^(attempt-1).
  /// Has no effect if there is nothing pending or all retries are exhausted.
  Future<void> retryAlert() async {
    if (_pendingAlert == null || state.retryCount >= maxRetries) return;

    final attempt = state.retryCount + 1;
    state = state.copyWith(
      isSending: true,
      hasSendError: false,
      retryCount: attempt,
    );

    // Exponential backoff: 500 ms, 1 s, 2 s, 4 s, 8 s
    final delay = Duration(milliseconds: 500 * (1 << (attempt - 1)));
    await Future.delayed(delay);

    // Guard against disposal during the backoff delay.
    if (_isDisposed) return;

    await _doSend();
  }

  Future<void> _doSend() async {
    final alert = _pendingAlert;
    if (alert == null) return;

    try {
      await _repository.sendAlert(
        type: alert.type,
        latitude: alert.latitude,
        longitude: alert.longitude,
        message: alert.message,
      );

      if (_isDisposed) return;

      final emergencyAlert = EmergencyAlert(
        sender: _myPeerId,
        type: alert.type,
        latitude: alert.latitude,
        longitude: alert.longitude,
        message: alert.message,
        isLocal: true,
      );

      _pendingAlert = null;
      final updatedAlerts = [...state.alerts, emergencyAlert];
      state = state.copyWith(
        alerts: updatedAlerts.length > _maxAlerts
            ? updatedAlerts.sublist(updatedAlerts.length - _maxAlerts)
            : updatedAlerts,
        isSending: false,
        hasSendError: false,
        retryCount: 0,
      );
    } catch (e) {
      SecureLogger.warning('EmergencyController: sendAlert failed: $e');
      if (_isDisposed) return;
      state = state.copyWith(isSending: false, hasSendError: true);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _alertSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
