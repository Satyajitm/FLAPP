import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../identity/peer_id.dart';
import '../transport/transport.dart';
import '../transport/transport_config.dart';

/// Provides the [Transport] instance (BLE or stub).
///
/// Override this in main.dart or a test harness to supply the actual
/// implementation.
final transportProvider = Provider<Transport>((ref) {
  throw UnimplementedError(
    'transportProvider must be overridden with a concrete Transport '
    'implementation before use.',
  );
});

/// Provides the local device's [PeerId].
///
/// Override this after identity initialization in main.dart.
final myPeerIdProvider = Provider<PeerId>((ref) {
  throw UnimplementedError(
    'myPeerIdProvider must be overridden with the device PeerId '
    'after identity initialization.',
  );
});

/// Provides the [TransportConfig].
final transportConfigProvider = Provider<TransportConfig>((ref) {
  return TransportConfig.defaultConfig;
});
