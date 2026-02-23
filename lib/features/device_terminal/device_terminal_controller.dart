import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  DeviceTerminalController({
    required DeviceTerminalRepository repository,
  })  : _repository = repository,
        super(const DeviceTerminalState()) {
    _listenForConnectionStatus();
    _listenForData();
  }

  void _listenForConnectionStatus() {
    _statusSub = _repository.onConnectionStatusChanged.listen((status) {
      state = state.copyWith(connectionStatus: status);
      if (status == DeviceConnectionStatus.disconnected) {
        state = state.copyWith(connectedDeviceName: null);
      }
    });
  }

  void _listenForData() {
    _dataSub = _repository.onDataReceived.listen((data) {
      final msg = TerminalMessage(
        id: 'rx_${_messageCounter++}',
        data: data,
        direction: TerminalDirection.incoming,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(messages: [...state.messages, msg]);
    });
  }

  /// Start scanning for Fluxon hardware devices.
  Future<void> startScan() async {
    state = state.copyWith(
      connectionStatus: DeviceConnectionStatus.scanning,
      scanResults: [],
    );
    _scanSub?.cancel();
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
    final data = Uint8List.fromList(utf8.encode(text));
    await _send(data);
  }

  /// Send hex string as raw bytes to the device (e.g. "0A 1B FF").
  Future<void> sendHex(String hexString) async {
    final cleaned = hexString.replaceAll(RegExp(r'[\s,]'), '');
    if (cleaned.isEmpty || cleaned.length.isOdd) return;
    final data = Uint8List(cleaned.length ~/ 2);
    for (var i = 0; i < data.length; i++) {
      data[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    await _send(data);
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
      state = state.copyWith(
        messages: [...state.messages, msg],
        isSending: false,
      );
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
    _scanSub?.cancel();
    _dataSub?.cancel();
    _statusSub?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
