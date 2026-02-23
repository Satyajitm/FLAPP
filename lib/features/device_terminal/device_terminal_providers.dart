import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'data/ble_device_terminal_repository.dart';
import 'data/device_terminal_repository.dart';
import 'device_terminal_controller.dart';

/// Provides the [DeviceTerminalRepository] implementation.
final deviceTerminalRepositoryProvider =
    Provider<DeviceTerminalRepository>((ref) {
  final repository = BleDeviceTerminalRepository();
  ref.onDispose(() => repository.dispose());
  return repository;
});

/// Provides the [DeviceTerminalController] StateNotifier.
final deviceTerminalControllerProvider =
    StateNotifierProvider<DeviceTerminalController, DeviceTerminalState>((ref) {
  final repository = ref.watch(deviceTerminalRepositoryProvider);
  return DeviceTerminalController(repository: repository);
});
