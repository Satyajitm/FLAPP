import 'dart:async';
import '../emergency_controller.dart';

/// Abstract interface for emergency alert data operations (DIP).
///
/// Decouples [EmergencyController] from transport, protocol, and encoding.
/// Mirrors the pattern used by [ChatRepository] and [LocationRepository].
abstract class EmergencyRepository {
  /// Stream of incoming emergency alerts from the mesh, fully decoded.
  Stream<EmergencyAlert> get onAlertReceived;

  /// Send an emergency alert broadcast to all peers.
  ///
  /// Handles encoding, packet construction, and re-broadcasting.
  Future<void> sendAlert({
    required EmergencyAlertType type,
    required double latitude,
    required double longitude,
    String message,
  });

  /// Release any resources held by this repository.
  void dispose();
}
