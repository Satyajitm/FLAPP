import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'device_terminal_controller.dart';
import 'device_terminal_model.dart';
import 'device_terminal_providers.dart';

/// BLE serial terminal screen for connecting to an external Fluxon device.
class DeviceTerminalScreen extends ConsumerStatefulWidget {
  const DeviceTerminalScreen({super.key});

  @override
  ConsumerState<DeviceTerminalScreen> createState() =>
      _DeviceTerminalScreenState();
}

class _DeviceTerminalScreenState extends ConsumerState<DeviceTerminalScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    final controller = ref.read(deviceTerminalControllerProvider.notifier);
    final state = ref.read(deviceTerminalControllerProvider);
    if (state.displayMode == TerminalDisplayMode.hex) {
      controller.sendHex(text).then((success) {
        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid hex input: use 0–9 and A–F characters only')),
          );
        }
      });
    } else {
      controller.sendText(text);
    }
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
    final state = ref.watch(deviceTerminalControllerProvider);
    final isConnected =
        state.connectionStatus == DeviceConnectionStatus.connected;

    if (state.messages.isNotEmpty) {
      _scrollToBottom();
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Device Terminal',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            if (state.connectedDeviceName != null)
              Text(
                state.connectedDeviceName!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
        actions: [
          _ConnectionStatusChip(status: state.connectionStatus),
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear log',
              onPressed: () =>
                  ref.read(deviceTerminalControllerProvider.notifier).clearLog(),
            ),
        ],
      ),
      body: isConnected
          ? _buildTerminalView(state)
          : _buildScanView(state),
    );
  }

  // ---------------------------------------------------------------------------
  // Scan view (disconnected / scanning)
  // ---------------------------------------------------------------------------

  Widget _buildScanView(DeviceTerminalState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final isScanning =
        state.connectionStatus == DeviceConnectionStatus.scanning;
    final isConnecting =
        state.connectionStatus == DeviceConnectionStatus.connecting;

    return Column(
      children: [
        // Scan button
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: isScanning || isConnecting
                ? null
                : () => ref
                    .read(deviceTerminalControllerProvider.notifier)
                    .startScan(),
            icon: isScanning
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.bluetooth_searching, size: 18),
            label: Text(isScanning ? 'Scanning...' : 'Scan for Devices'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),

        // Device list
        Expanded(
          child: state.scanResults.isEmpty
              ? _buildEmptyScanState(isScanning)
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: state.scanResults.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final device = state.scanResults[index];
                    return _DeviceTile(
                      device: device,
                      isConnecting: isConnecting,
                      onConnect: () => ref
                          .read(deviceTerminalControllerProvider.notifier)
                          .connect(device),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyScanState(bool isScanning) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
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
              Icons.developer_board_outlined,
              size: 36,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isScanning ? 'Searching...' : 'No devices found',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isScanning
                ? 'Looking for Fluxon hardware nearby.'
                : 'Tap scan to search for Fluxon devices.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Terminal view (connected)
  // ---------------------------------------------------------------------------

  Widget _buildTerminalView(DeviceTerminalState state) {
    return Column(
      children: [
        // Top bar: disconnect + display mode toggle
        _buildTerminalTopBar(state),
        const Divider(height: 1),

        // Message log
        Expanded(
          child: state.messages.isEmpty
              ? _buildEmptyTerminalState()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: state.messages.length,
                  itemBuilder: (context, index) {
                    return _TerminalMessageBubble(
                      message: state.messages[index],
                      displayMode: state.displayMode,
                    );
                  },
                ),
        ),

        // Input bar
        _buildInputBar(
          isSending: state.isSending,
          mode: state.displayMode,
        ),
      ],
    );
  }

  Widget _buildTerminalTopBar(DeviceTerminalState state) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Disconnect button
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(deviceTerminalControllerProvider.notifier).disconnect(),
            icon: const Icon(Icons.link_off, size: 16),
            label: const Text('Disconnect'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.error,
              side: BorderSide(color: colorScheme.error),
            ),
          ),
          const Spacer(),
          // Display mode toggle
          SegmentedButton<TerminalDisplayMode>(
            segments: const [
              ButtonSegment(
                value: TerminalDisplayMode.text,
                label: Text('Text'),
                icon: Icon(Icons.text_fields, size: 16),
              ),
              ButtonSegment(
                value: TerminalDisplayMode.hex,
                label: Text('Hex'),
                icon: Icon(Icons.data_array, size: 16),
              ),
            ],
            selected: {state.displayMode},
            onSelectionChanged: (_) => ref
                .read(deviceTerminalControllerProvider.notifier)
                .toggleDisplayMode(),
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyTerminalState() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal,
            size: 48,
            color: colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Terminal ready',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Send a message to the device.',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.outlineVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar({
    required bool isSending,
    required TerminalDisplayMode mode,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final hintText = mode == TerminalDisplayMode.hex
        ? 'Enter hex (e.g. 0A 1B FF)...'
        : 'Type message...';

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
                textCapitalization: mode == TerminalDisplayMode.text
                    ? TextCapitalization.sentences
                    : TextCapitalization.none,
                decoration: InputDecoration(
                  hintText: hintText,
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
                onSubmitted: (_) => _send(),
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
                      onPressed: _send,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

class _ConnectionStatusChip extends StatelessWidget {
  final DeviceConnectionStatus status;

  const _ConnectionStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      DeviceConnectionStatus.disconnected => ('Disconnected', Colors.grey),
      DeviceConnectionStatus.scanning => ('Scanning', Colors.orange),
      DeviceConnectionStatus.connecting => ('Connecting', Colors.orange),
      DeviceConnectionStatus.connected => ('Connected', Colors.green),
      DeviceConnectionStatus.disconnecting => ('Disconnecting', Colors.orange),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final ScannedDevice device;
  final bool isConnecting;
  final VoidCallback onConnect;

  const _DeviceTile({
    required this.device,
    required this.isConnecting,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.bluetooth,
          color: colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Text(
        device.name.isNotEmpty ? device.name : 'Unknown Device',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${device.id}  •  ${device.rssi} dBm',
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: isConnecting
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton(
              onPressed: onConnect,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Connect'),
            ),
    );
  }
}

class _TerminalMessageBubble extends StatelessWidget {
  final TerminalMessage message;
  final TerminalDisplayMode displayMode;

  const _TerminalMessageBubble({
    required this.message,
    required this.displayMode,
  });

  @override
  Widget build(BuildContext context) {
    final isOutgoing = message.direction == TerminalDirection.outgoing;
    final colorScheme = Theme.of(context).colorScheme;
    final displayText =
        displayMode == TerminalDisplayMode.hex ? message.hexView : message.textView;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: isOutgoing
              ? colorScheme.primary
              : colorScheme.surfaceContainerLow,
          border: isOutgoing
              ? null
              : Border.all(color: colorScheme.outlineVariant, width: 0.5),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft:
                isOutgoing ? const Radius.circular(16) : const Radius.circular(4),
            bottomRight:
                isOutgoing ? const Radius.circular(4) : const Radius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Direction label
            Text(
              isOutgoing ? 'TX' : 'RX',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: isOutgoing
                    ? Colors.white.withValues(alpha: 0.7)
                    : colorScheme.primary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            // Data
            Text(
              displayText,
              style: TextStyle(
                fontSize: displayMode == TerminalDisplayMode.hex ? 13 : 15,
                fontFamily:
                    displayMode == TerminalDisplayMode.hex ? 'monospace' : null,
                color: isOutgoing ? Colors.white : colorScheme.onSurface,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 4),
            // Timestamp + byte count
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                '${_formatTime(message.timestamp)}  •  ${message.data.length} bytes',
                style: TextStyle(
                  fontSize: 10,
                  color: isOutgoing
                      ? Colors.white.withValues(alpha: 0.65)
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
