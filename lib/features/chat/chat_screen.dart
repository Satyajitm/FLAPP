import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/identity/peer_id.dart';
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

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    ref.read(chatControllerProvider.notifier).sendMessage(text);
  }

  void _showPeerPicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _PeerPickerSheet(
        onPeerSelected: (peer) {
          Navigator.of(ctx).pop();
          ref.read(chatControllerProvider.notifier).selectPeer(peer);
        },
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatControllerProvider);
    final messages = chatState.messages;

    // Auto-scroll when new messages arrive
    if (messages.isNotEmpty) {
      _scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Group Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.people),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('Create Group'),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).pushNamed('/create-group');
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.login),
                        title: const Text('Join Group'),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).pushNamed('/join-group');
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text(
                      'No messages yet.\nStart chatting with your group!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return _MessageBubble(message: msg);
                    },
                  ),
          ),
          _buildInputBar(
            isSending: chatState.isSending,
            selectedPeer: chatState.selectedPeer,
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar({
    required bool isSending,
    required PeerId? selectedPeer,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectedPeer != null) _buildPeerSelector(selectedPeer),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  Icons.person_add,
                  color: selectedPeer != null
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                tooltip: 'Send private message',
                onPressed: _showPeerPicker,
              ),
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: InputDecoration(
                    hintText: selectedPeer != null
                        ? 'Private message...'
                        : 'Type a message...',
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                onPressed: isSending ? null : _sendMessage,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPeerSelector(PeerId selectedPeer) {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.lock, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Private to ${selectedPeer.shortId}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.primary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () {
                ref.read(chatControllerProvider.notifier).selectPeer(null);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isLocal = message.isLocal;
    return Align(
      alignment: isLocal ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isLocal
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isLocal)
              Text(
                message.sender.shortId,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isLocal ? Colors.white70 : Colors.grey,
                ),
              ),
            Text(
              message.text,
              style: TextStyle(
                color: isLocal ? Colors.white : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                fontSize: 10,
                color: isLocal ? Colors.white54 : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// Bottom sheet for selecting a peer for private messaging.
class _PeerPickerSheet extends ConsumerWidget {
  final Function(PeerId) onPeerSelected;

  const _PeerPickerSheet({required this.onPeerSelected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = ref.watch(transportProvider);
    final connectedPeersAsyncValue = ref.watch(
      StreamProvider((ref) => transport.connectedPeers),
    );

    return SafeArea(
      child: SingleChildScrollView(
        child: connectedPeersAsyncValue.when(
          data: (peers) {
            if (peers.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No connected peers.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600]),
                ),
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Select a peer for private message',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ...peers.map(
                  (peer) => ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(
                      PeerId(peer.peerId).shortId,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text('RSSI: ${peer.rssi}'),
                    onTap: () => onPeerSelected(PeerId(peer.peerId)),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(),
          ),
          error: (err, stack) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Error loading peers: $err'),
          ),
        ),
      ),
    );
  }
}
