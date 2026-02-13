import 'dart:async';
import 'dart:typed_data';
import '../protocol/packet.dart';
import 'transport.dart';

/// No-op transport for platforms without BLE (web, desktop testing).
///
/// Broadcast and send are silent no-ops. No packets are ever received
/// from the network, but the controller can still manage local state.
class StubTransport extends Transport {
  final Uint8List _myPeerId;
  final _packetController = StreamController<FluxonPacket>.broadcast();
  final _peersController = StreamController<List<PeerConnection>>.broadcast();
  bool _running = false;

  StubTransport({required Uint8List myPeerId}) : _myPeerId = myPeerId;

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
    return true; // No-op success
  }

  @override
  Future<void> broadcastPacket(FluxonPacket packet) async {
    // No-op: no connected peers on stub transport
  }

  void dispose() {
    _packetController.close();
    _peersController.close();
  }
}
