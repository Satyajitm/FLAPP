import 'dart:typed_data';

/// Direction of a terminal message.
enum TerminalDirection {
  /// Sent from phone to device (TX).
  outgoing,

  /// Received from device to phone (RX).
  incoming,
}

/// Display mode for the terminal log.
enum TerminalDisplayMode {
  /// Show data as UTF-8 text.
  text,

  /// Show data as hex bytes (e.g. "0A 1B FF").
  hex,
}

/// BLE connection status for the external device.
enum DeviceConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
}

/// A single terminal message (sent or received).
class TerminalMessage {
  final String id;
  final Uint8List data;
  final TerminalDirection direction;
  final DateTime timestamp;

  const TerminalMessage({
    required this.id,
    required this.data,
    required this.direction,
    required this.timestamp,
  });

  /// Render as UTF-8 text (lossy — replaces invalid bytes).
  String get textView => String.fromCharCodes(data);

  /// Render as spaced hex string (e.g. "0A 1B FF").
  String get hexView =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

/// A BLE device discovered during scanning.
class ScannedDevice {
  /// Platform device ID (MAC on Android, UUID on iOS).
  final String id;

  /// Advertised device name, or empty string.
  final String name;

  /// Signal strength in dBm.
  final int rssi;

  const ScannedDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });
}
