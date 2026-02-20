import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
import '../../core/providers/group_providers.dart';
import '../../core/providers/profile_providers.dart';
import '../../core/services/receipt_service.dart';
import '../../core/transport/transport.dart';
import '../../core/transport/transport_config.dart';
import 'data/chat_repository.dart';
import 'data/mesh_chat_repository.dart';
import 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Core infrastructure providers
// ---------------------------------------------------------------------------

/// Provides the [Transport] instance (BLE or future Fluxo hardware).
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

// ---------------------------------------------------------------------------
// Chat feature providers
// ---------------------------------------------------------------------------

/// Provides the [ReceiptService] for delivery/read receipts.
final receiptServiceProvider = Provider<ReceiptService>((ref) {
  final transport = ref.watch(transportProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  final groupManager = ref.watch(groupManagerProvider);
  final service = ReceiptService(
    transport: transport,
    myPeerId: myPeerId,
    groupManager: groupManager,
  );
  service.start();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provides the [ChatRepository] implementation.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final transport = ref.watch(transportProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  final groupManager = ref.watch(groupManagerProvider);
  final receiptService = ref.watch(receiptServiceProvider);
  final repository = MeshChatRepository(
    transport: transport,
    myPeerId: myPeerId,
    groupManager: groupManager,
    receiptService: receiptService,
  );
  ref.onDispose(() => repository.dispose());
  return repository;
});

/// Provides the [ChatController] StateNotifier.
final chatControllerProvider =
    StateNotifierProvider<ChatController, ChatState>((ref) {
  final repository = ref.watch(chatRepositoryProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  return ChatController(
    repository: repository,
    myPeerId: myPeerId,
    // Read at send time so name changes are reflected immediately.
    getDisplayName: () => ref.read(displayNameProvider),
  );
});
