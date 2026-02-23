import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/features/device_terminal/data/device_terminal_repository.dart';
import 'package:fluxon_app/features/device_terminal/device_terminal_controller.dart';
import 'package:fluxon_app/features/device_terminal/device_terminal_model.dart';

// ---------------------------------------------------------------------------
// Stub repository for testing
// ---------------------------------------------------------------------------

class StubDeviceTerminalRepository implements DeviceTerminalRepository {
  final _scanController = StreamController<List<ScannedDevice>>.broadcast();
  final _dataController = StreamController<Uint8List>.broadcast();
  final _statusController =
      StreamController<DeviceConnectionStatus>.broadcast();

  final List<Uint8List> sentData = [];
  bool startScanCalled = false;
  bool stopScanCalled = false;
  String? connectedDeviceId;
  bool disconnectCalled = false;
  bool disposed = false;

  @override
  Stream<List<ScannedDevice>> get onScanResults => _scanController.stream;

  @override
  Stream<Uint8List> get onDataReceived => _dataController.stream;

  @override
  Stream<DeviceConnectionStatus> get onConnectionStatusChanged =>
      _statusController.stream;

  @override
  Future<void> startScan() async {
    startScanCalled = true;
  }

  @override
  Future<void> stopScan() async {
    stopScanCalled = true;
  }

  @override
  Future<void> connect(String deviceId) async {
    connectedDeviceId = deviceId;
    _statusController.add(DeviceConnectionStatus.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    _statusController.add(DeviceConnectionStatus.disconnected);
  }

  @override
  Future<void> send(Uint8List data) async {
    sentData.add(data);
  }

  @override
  void dispose() {
    disposed = true;
    _scanController.close();
    _dataController.close();
    _statusController.close();
  }

  // Test helpers
  void emitScanResults(List<ScannedDevice> devices) =>
      _scanController.add(devices);

  void emitData(Uint8List data) => _dataController.add(data);

  void emitStatus(DeviceConnectionStatus status) =>
      _statusController.add(status);
}

void main() {
  late StubDeviceTerminalRepository repository;
  late DeviceTerminalController controller;

  setUp(() {
    repository = StubDeviceTerminalRepository();
    controller = DeviceTerminalController(repository: repository);
  });

  tearDown(() {
    controller.dispose();
  });

  test('initial state is disconnected with empty messages', () {
    expect(controller.state.connectionStatus,
        DeviceConnectionStatus.disconnected);
    expect(controller.state.messages, isEmpty);
    expect(controller.state.scanResults, isEmpty);
    expect(controller.state.displayMode, TerminalDisplayMode.text);
    expect(controller.state.isSending, false);
    expect(controller.state.connectedDeviceName, isNull);
  });

  test('startScan sets scanning status and clears scan results', () async {
    await controller.startScan();

    expect(repository.startScanCalled, true);
    expect(controller.state.connectionStatus,
        DeviceConnectionStatus.scanning);
  });

  test('scan results update state', () async {
    await controller.startScan();

    const device = ScannedDevice(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'Fluxon-01',
      rssi: -55,
    );
    repository.emitScanResults([device]);

    // Allow stream event to propagate.
    await Future.delayed(Duration.zero);

    expect(controller.state.scanResults, hasLength(1));
    expect(controller.state.scanResults.first.name, 'Fluxon-01');
  });

  test('connect sets connecting status and device name', () async {
    const device = ScannedDevice(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'Fluxon-01',
      rssi: -55,
    );

    await controller.connect(device);
    await Future.delayed(Duration.zero);

    expect(repository.connectedDeviceId, 'AA:BB:CC:DD:EE:FF');
    expect(controller.state.connectionStatus,
        DeviceConnectionStatus.connected);
    expect(controller.state.connectedDeviceName, 'Fluxon-01');
  });

  test('connect uses device id as name when name is empty', () async {
    const device = ScannedDevice(id: 'AA:BB', name: '', rssi: -70);

    await controller.connect(device);
    await Future.delayed(Duration.zero);

    expect(controller.state.connectedDeviceName, 'AA:BB');
  });

  test('disconnect calls repository and clears device name', () async {
    await controller.disconnect();
    await Future.delayed(Duration.zero);

    expect(repository.disconnectCalled, true);
    expect(controller.state.connectionStatus,
        DeviceConnectionStatus.disconnected);
    expect(controller.state.connectedDeviceName, isNull);
  });

  test('sendText adds outgoing message to state', () async {
    await controller.sendText('Hello');
    await Future.delayed(Duration.zero);

    expect(repository.sentData, hasLength(1));
    expect(controller.state.messages, hasLength(1));
    expect(controller.state.messages.first.direction,
        TerminalDirection.outgoing);
    expect(controller.state.messages.first.textView, 'Hello');
  });

  test('sendText ignores empty text', () async {
    await controller.sendText('');

    expect(repository.sentData, isEmpty);
    expect(controller.state.messages, isEmpty);
  });

  test('sendHex parses hex correctly and sends bytes', () async {
    await controller.sendHex('0A 1B FF');
    await Future.delayed(Duration.zero);

    expect(repository.sentData, hasLength(1));
    expect(repository.sentData.first, [0x0A, 0x1B, 0xFF]);
    expect(controller.state.messages, hasLength(1));
    expect(controller.state.messages.first.hexView, '0A 1B FF');
  });

  test('sendHex rejects odd-length hex string', () async {
    await controller.sendHex('0A1');

    expect(repository.sentData, isEmpty);
    expect(controller.state.messages, isEmpty);
  });

  test('sendHex strips spaces and commas', () async {
    await controller.sendHex('0A, 1B, FF');
    await Future.delayed(Duration.zero);

    expect(repository.sentData, hasLength(1));
    expect(repository.sentData.first, [0x0A, 0x1B, 0xFF]);
  });

  test('incoming data adds incoming message to state', () async {
    repository.emitData(Uint8List.fromList([0x48, 0x69]));
    await Future.delayed(Duration.zero);

    expect(controller.state.messages, hasLength(1));
    expect(controller.state.messages.first.direction,
        TerminalDirection.incoming);
    expect(controller.state.messages.first.textView, 'Hi');
  });

  test('toggleDisplayMode switches between text and hex', () {
    expect(controller.state.displayMode, TerminalDisplayMode.text);

    controller.toggleDisplayMode();
    expect(controller.state.displayMode, TerminalDisplayMode.hex);

    controller.toggleDisplayMode();
    expect(controller.state.displayMode, TerminalDisplayMode.text);
  });

  test('clearLog empties message list', () async {
    await controller.sendText('test');
    await Future.delayed(Duration.zero);
    expect(controller.state.messages, isNotEmpty);

    controller.clearLog();
    expect(controller.state.messages, isEmpty);
  });

  test('stopScan calls repository stopScan', () async {
    await controller.startScan();
    await controller.stopScan();

    expect(repository.stopScanCalled, true);
  });
}
