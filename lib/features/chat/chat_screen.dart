import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/group_providers.dart';
import '../../core/providers/profile_providers.dart';
import '../../core/services/notification_sound.dart';
import 'chat_controller.dart';
import 'chat_providers.dart';
import 'message_model.dart';

/// Group chat UI screen.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _notificationSound = NotificationSoundService();

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _notificationSound.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    ref.read(chatControllerProvider.notifier).sendMessage(text);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _showGroupMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final displayName = ref.read(displayNameProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Settings',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(displayName.isNotEmpty ? displayName : 'Set your name'),
                subtitle: const Text('Tap to change'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showChangeNameDialog();
                },
              ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Group',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('Create Group'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pushNamed('/create-group');
                },
              ),
              ListTile(
                leading: const Icon(Icons.login_outlined),
                title: const Text('Join Group'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pushNamed('/join-group');
                },
              ),
              if (ref.read(activeGroupProvider) != null)
                ListTile(
                  leading: Icon(Icons.logout_outlined, color: Colors.red[400]),
                  title: Text('Leave Group', style: TextStyle(color: Colors.red[400])),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    ref.read(groupManagerProvider).leaveGroup();
                    ref.read(activeGroupProvider.notifier).state = null;
                  },
                ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Chat',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.delete_sweep_outlined, color: Colors.red[400]),
                title: Text('Clear Chat', style: TextStyle(color: Colors.red[400])),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmClearChat();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showChangeNameDialog() {
    final controller = TextEditingController(
      text: ref.read(displayNameProvider),
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Enter your name',
          ),
          onSubmitted: (_) => _commitNameChange(ctx, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => _commitNameChange(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  Future<void> _commitNameChange(BuildContext ctx, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await ref.read(userProfileManagerProvider).setName(trimmed);
    ref.read(displayNameProvider.notifier).state = trimmed;
    if (ctx.mounted) Navigator.of(ctx).pop();
  }

  /// Show confirmation dialog before clearing all messages.
  void _confirmClearChat() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'All messages will be permanently deleted from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(chatControllerProvider.notifier).clearAllMessages();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red[400],
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  /// Show confirmation dialog before deleting a single message.
  void _confirmDeleteMessage(String messageId) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This message will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(chatControllerProvider.notifier).deleteMessage(messageId);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red[400],
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Play notification sound and send read receipts when new incoming messages arrive.
    ref.listen<ChatState>(chatControllerProvider, (previous, next) {
      if (previous == null) return;
      if (next.messages.length > previous.messages.length) {
        final newMessages = next.messages.sublist(previous.messages.length);
        final incoming = newMessages.where((m) => !m.isLocal).toList();
        if (incoming.isNotEmpty) {
          _notificationSound.play();
          // Chat screen is open, so mark as read immediately
          ref.read(chatControllerProvider.notifier).markMessagesAsRead(incoming);
        }
      }
    });

    final chatState = ref.watch(chatControllerProvider);
    final group = ref.watch(activeGroupProvider);
    final messages = chatState.messages;

    if (messages.isNotEmpty) {
      _scrollToBottom();
    }

    final memberCount = group?.members.length ?? 0;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: group != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    memberCount == 0
                        ? 'Mesh active'
                        : '$memberCount member${memberCount == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              )
            : const Text(
                'No Group',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Group options',
            onPressed: _showGroupMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: group == null
                ? _buildNoGroupState(context)
                : messages.isEmpty
                    ? _buildEmptyMessagesState(context)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          return _MessageBubble(
                            key: ValueKey(messages[index].id),
                            message: messages[index],
                            onLongPress: () =>
                                _confirmDeleteMessage(messages[index].id),
                          );
                        },
                      ),
          ),
          if (group != null) _buildInputBar(isSending: chatState.isSending),
        ],
      ),
    );
  }

  Widget _buildNoGroupState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.hub_outlined,
                size: 36,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Join your group',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create or join a group to start chatting with people nearby.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pushNamed('/create-group'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create Group'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pushNamed('/join-group'),
              icon: const Icon(Icons.login, size: 18),
              label: const Text('Join Group'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMessagesState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Say hello to your group!',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.outlineVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar({required bool isSending}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message group...',
                  hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerLowest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: colorScheme.outlineVariant,
                      width: 0.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: colorScheme.primary,
                      width: 1.5,
                    ),
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: isSending
                  ? SizedBox(
                      key: const ValueKey('loading'),
                      width: 40,
                      height: 40,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      ),
                    )
                  : IconButton(
                      key: const ValueKey('send'),
                      icon: const Icon(Icons.send_rounded),
                      color: colorScheme.primary,
                      onPressed: _sendMessage,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onLongPress;

  const _MessageBubble({super.key, required this.message, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final isLocal = message.isLocal;
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isLocal ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: isLocal
              ? colorScheme.primary
              : colorScheme.surfaceContainerLow,
          border: isLocal
              ? null
              : Border.all(color: colorScheme.outlineVariant, width: 0.5),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: isLocal ? const Radius.circular(16) : const Radius.circular(4),
            bottomRight: isLocal ? const Radius.circular(4) : const Radius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isLocal)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  message.senderName.isNotEmpty
                      ? message.senderName
                      : message.sender.shortId,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            Text(
              message.text,
              style: TextStyle(
                fontSize: 15,
                color: isLocal ? Colors.white : colorScheme.onSurface,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.bottomRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(message.timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      color: isLocal
                          ? Colors.white.withValues(alpha: 0.65)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (isLocal) ...[
                    const SizedBox(width: 4),
                    Icon(
                      message.status == MessageStatus.read ||
                              message.status == MessageStatus.delivered
                          ? Icons.done_all
                          : Icons.done,
                      size: 14,
                      color: message.status == MessageStatus.read
                          ? Colors.lightBlueAccent
                          : Colors.white.withValues(alpha: 0.65),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
