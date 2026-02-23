import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/features/device_terminal/device_terminal_model.dart';

void main() {
  group('TerminalMessage', () {
    test('textView returns ASCII text', () {
      final msg = TerminalMessage(
        id: 'test_1',
        data: Uint8List.fromList([72, 101, 108, 108, 111]), // "Hello"
        direction: TerminalDirection.outgoing,
        timestamp: DateTime(2026, 1, 1),
      );

      expect(msg.textView, 'Hello');
    });

    test('textView handles non-ASCII bytes', () {
      final msg = TerminalMessage(
        id: 'test_2',
        data: Uint8List.fromList([0xFF, 0x00, 0x41]),
        direction: TerminalDirection.incoming,
        timestamp: DateTime(2026, 1, 1),
      );

      // String.fromCharCodes is lossy for non-UTF8 — just verify it doesn't crash
      expect(msg.textView, isNotEmpty);
    });

    test('hexView formats bytes as uppercase spaced hex', () {
      final msg = TerminalMessage(
        id: 'test_3',
        data: Uint8List.fromList([0x0A, 0x1B, 0xFF, 0x00]),
        direction: TerminalDirection.outgoing,
        timestamp: DateTime(2026, 1, 1),
      );

      expect(msg.hexView, '0A 1B FF 00');
    });

    test('hexView handles empty data', () {
      final msg = TerminalMessage(
        id: 'test_4',
        data: Uint8List(0),
        direction: TerminalDirection.incoming,
        timestamp: DateTime(2026, 1, 1),
      );

      expect(msg.hexView, '');
    });

    test('hexView handles single byte', () {
      final msg = TerminalMessage(
        id: 'test_5',
        data: Uint8List.fromList([0x42]),
        direction: TerminalDirection.outgoing,
        timestamp: DateTime(2026, 1, 1),
      );

      expect(msg.hexView, '42');
    });
  });

  group('ScannedDevice', () {
    test('stores id, name, and rssi', () {
      const device = ScannedDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'Fluxon-01',
        rssi: -65,
      );

      expect(device.id, 'AA:BB:CC:DD:EE:FF');
      expect(device.name, 'Fluxon-01');
      expect(device.rssi, -65);
    });
  });
}
