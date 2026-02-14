import 'dart:async';
import 'dart:typed_data';
import '../protocol/packet.dart';
import 'transport.dart';

/// No-op transport for platforms without BLE (web, desktop testing).
///
/// Supports an optional loopback mode where [broadcastPacket] echoes
/// the packet back into [onPacketReceived], useful for UI development.
/// Also exposes [simulateIncomingPacket] for injecting fake remote messages.
class StubTransport extends Transport {
  final Uint8List _myPeerId;
  final bool loopback;
  final _packetController = StreamController<FluxonPacket>.broadcast();
  final _peersController = StreamController<List<PeerConnection>>.broadcast();
  bool _running = false;

  StubTransport({
    required Uint8List myPeerId,
    this.loopback = false,
  }) : _myPeerId = myPeerId;

  @override
  Uint8List get myPeerId => _myPeerId;

  @override
  bool get isRunning => _running;

  @override
  Stream<FluxonPacket> get onPacketReceived => _packetController.stream;

  @override
  Stream<List<PeerConnection>> get connectedPeers => _peersController.stream;

  @override
  Future<void> startServices() async {
    _running = true;
  }

  @override
  Future<void> stopServices() async {
    _running = false;
  }

  @override
  Future<bool> sendPacket(FluxonPacket packet, Uint8List peerId) async {
    if (loopback) {
      _packetController.add(packet);
    }
    return true;
  }

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    if (loopback) {
      _packetController.add(packet);
    }
  }

  /// Inject a packet as if it arrived from a remote peer.
  void simulateIncomingPacket(FluxonPacket packet) {
    _packetController.add(packet);
  }

  void dispose() {
    _packetController.close();
    _peersController.close();
  }
}
