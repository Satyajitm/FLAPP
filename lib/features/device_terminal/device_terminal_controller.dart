import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/logger.dart';
import 'data/device_terminal_repository.dart';
import 'device_terminal_model.dart';

/// Terminal state — immutable, rebuilt via copyWith.
class DeviceTerminalState {
  final DeviceConnectionStatus connectionStatus;
  final List<ScannedDevice> scanResults;
  final List<TerminalMessage> messages;
  final TerminalDisplayMode displayMode;
  final bool isSending;
  final String? connectedDeviceName;

  const DeviceTerminalState({
    this.connectionStatus = DeviceConnectionStatus.disconnected,
    this.scanResults = const [],
    this.messages = const [],
    this.displayMode = TerminalDisplayMode.text,
    this.isSending = false,
    this.connectedDeviceName,
  });

  DeviceTerminalState copyWith({
    DeviceConnectionStatus? connectionStatus,
    List<ScannedDevice>? scanResults,
    List<TerminalMessage>? messages,
    TerminalDisplayMode? displayMode,
    bool? isSending,
    String? connectedDeviceName,
  }) {
    return DeviceTerminalState(
      connectionStatus: connectionStatus ?? this.connectionStatus,
      scanResults: scanResults ?? this.scanResults,
      messages: messages ?? this.messages,
      displayMode: displayMode ?? this.displayMode,
      isSending: isSending ?? this.isSending,
      connectedDeviceName: connectedDeviceName ?? this.connectedDeviceName,
    );
  }
}

/// Device terminal controller — manages BLE scanning, connection, and
/// raw serial communication with an external Fluxon hardware device.
class DeviceTerminalController extends StateNotifier<DeviceTerminalState> {
  final DeviceTerminalRepository _repository;
  StreamSubscription? _scanSub;
  StreamSubscription? _dataSub;
  StreamSubscription? _statusSub;
  int _messageCounter = 0;
  bool _isDisposed = false;

  DeviceTerminalController({
    required DeviceTerminalRepository repository,
  })  : _repository = repository,
        super(const DeviceTerminalState()) {
    _listenForConnectionStatus();
    _listenForData();
  }

  /// Maximum number of terminal messages retained in memory (C5).
  static const _maxMessages = 500;

  void _listenForConnectionStatus() {
    // L9: Add onError handler to prevent unhandled stream errors.
    _statusSub = _repository.onConnectionStatusChanged.listen(
      (status) {
        state = state.copyWith(connectionStatus: status);
        if (status == DeviceConnectionStatus.disconnected) {
          state = state.copyWith(connectedDeviceName: null);
        }
      },
      onError: (Object e) {
        SecureLogger.warning('DeviceTerminal: connection status stream error: $e');
      },
      cancelOnError: false,
    );
  }

  void _listenForData() {
    // L9: Add onError handler to prevent unhandled stream errors.
    _dataSub = _repository.onDataReceived.listen(
      (data) {
        if (_isDisposed) return;
        final msg = TerminalMessage(
          id: 'rx_${_messageCounter++}',
          data: data,
          direction: TerminalDirection.incoming,
          timestamp: DateTime.now(),
        );
        // C5: Cap messages list at 500 to prevent unbounded memory growth.
        final updated = [...state.messages, msg];
        final capped = updated.length > _maxMessages
            ? updated.sublist(updated.length - _maxMessages)
            : updated;
        state = state.copyWith(messages: capped);
      },
      onError: (Object e) {
        SecureLogger.warning('DeviceTerminal: data stream error: $e');
      },
      cancelOnError: false,
    );
  }

  /// Start scanning for Fluxon hardware devices.
  Future<void> startScan() async {
    // L13: Cancel and null out the old subscription BEFORE starting a new scan
    // to avoid a race where the old callback fires after the new scan starts.
    await _scanSub?.cancel();
    _scanSub = null;
    state = state.copyWith(
      connectionStatus: DeviceConnectionStatus.scanning,
      scanResults: [],
    );
    _scanSub = _repository.onScanResults.listen((devices) {
      state = state.copyWith(scanResults: devices);
    });
    await _repository.startScan();
  }

  /// Stop scanning.
  Future<void> stopScan() async {
    _scanSub?.cancel();
    _scanSub = null;
    await _repository.stopScan();
    if (state.connectionStatus == DeviceConnectionStatus.scanning) {
      state = state.copyWith(connectionStatus: DeviceConnectionStatus.disconnected);
    }
  }

  /// Connect to a scanned device.
  Future<void> connect(ScannedDevice device) async {
    state = state.copyWith(
      connectionStatus: DeviceConnectionStatus.connecting,
      connectedDeviceName: device.name.isNotEmpty ? device.name : device.id,
    );
    await _repository.connect(device.id);
  }

  /// Disconnect from the current device.
  Future<void> disconnect() async {
    state = state.copyWith(connectionStatus: DeviceConnectionStatus.disconnecting);
    await _repository.disconnect();
  }

  /// Send text as UTF-8 bytes to the device.
  Future<void> sendText(String text) async {
    if (text.isEmpty) return;
    // L11: Reject oversized inputs before encoding.
    if (text.length > 512) return;
    final data = Uint8List.fromList(utf8.encode(text));
    await _send(data);
  }

  /// Send hex string as raw bytes to the device (e.g. "0A 1B FF").
  ///
  /// Returns false if [hexString] contains invalid hex characters.
  Future<bool> sendHex(String hexString) async {
    final cleaned = hexString.replaceAll(RegExp(r'[\s,]'), '');
    if (cleaned.isEmpty || cleaned.length.isOdd) return false;
    try {
      final data = Uint8List(cleaned.length ~/ 2);
      for (var i = 0; i < data.length; i++) {
        data[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
      }
      await _send(data);
      return true;
    } catch (_) {
      // Invalid hex character — return false so caller can surface error UI.
      return false;
    }
  }

  Future<void> _send(Uint8List data) async {
    state = state.copyWith(isSending: true);
    try {
      await _repository.send(data);
      final msg = TerminalMessage(
        id: 'tx_${_messageCounter++}',
        data: data,
        direction: TerminalDirection.outgoing,
        timestamp: DateTime.now(),
      );
      // C5: Cap messages list at 500 to prevent unbounded memory growth.
      final updated = [...state.messages, msg];
      final capped = updated.length > _maxMessages
          ? updated.sublist(updated.length - _maxMessages)
          : updated;
      state = state.copyWith(messages: capped, isSending: false);
    } catch (_) {
      state = state.copyWith(isSending: false);
    }
  }

  /// Toggle between text and hex display modes.
  void toggleDisplayMode() {
    state = state.copyWith(
      displayMode: state.displayMode == TerminalDisplayMode.text
          ? TerminalDisplayMode.hex
          : TerminalDisplayMode.text,
    );
  }

  /// Clear all terminal messages.
  void clearLog() {
    state = state.copyWith(messages: []);
    _messageCounter = 0;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scanSub?.cancel();
    _dataSub?.cancel();
    _statusSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
