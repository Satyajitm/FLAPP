import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/group_providers.dart';
import '../../core/providers/profile_providers.dart';
import '../../core/providers/transport_providers.dart';
import '../../core/services/message_storage_service.dart';
import '../../core/services/receipt_service.dart';
import 'data/chat_repository.dart';
import 'data/mesh_chat_repository.dart';
import 'chat_controller.dart';

// Re-export so existing imports of these providers from chat_providers.dart
// continue to resolve without changes across other files.
export '../../core/providers/transport_providers.dart'
    show transportProvider, myPeerIdProvider, transportConfigProvider;

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

/// Provides the [MessageStorageService] for local message persistence.
final messageStorageServiceProvider = Provider<MessageStorageService>((ref) {
  final service = MessageStorageService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provides the [ChatController] StateNotifier.
///
/// Watches [activeGroupProvider] so the controller (and its persisted
/// messages) are rebuilt whenever the user creates, joins, or leaves a group.
final chatControllerProvider =
    StateNotifierProvider<ChatController, ChatState>((ref) {
  final repository = ref.watch(chatRepositoryProvider);
  final myPeerId = ref.watch(myPeerIdProvider);
  final storageService = ref.watch(messageStorageServiceProvider);
  final activeGroup = ref.watch(activeGroupProvider);
  return ChatController(
    repository: repository,
    myPeerId: myPeerId,
    // Read at send time so name changes are reflected immediately.
    getDisplayName: () => ref.read(displayNameProvider),
    storageService: storageService,
    groupId: activeGroup?.id,
  );
});

