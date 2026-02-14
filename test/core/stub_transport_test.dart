import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

FluxonPacket _buildChatPacket(String text, {int senderByte = 0xAA}) {
  return BinaryProtocol.buildPacket(
    type: MessageType.chat,
    sourceId: Uint8List(32)..fillRange(0, 32, senderByte),
    payload: BinaryProtocol.encodeChatPayload(text),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('StubTransport', () {
    group('lifecycle', () {
      test('isRunning is false initially', () {
        final transport = StubTransport(myPeerId: Uint8List(32));
        expect(transport.isRunning, isFalse);
        transport.dispose();
      });

      test('startServices sets isRunning to true', () async {
        final transport = StubTransport(myPeerId: Uint8List(32));
        await transport.startServices();
        expect(transport.isRunning, isTrue);
        transport.dispose();
      });

      test('stopServices sets isRunning to false', () async {
        final transport = StubTransport(myPeerId: Uint8List(32));
        await transport.startServices();
        await transport.stopServices();
        expect(transport.isRunning, isFalse);
        transport.dispose();
      });

      test('myPeerId returns the provided peer ID', () {
        final peerId = Uint8List(32)..fillRange(0, 32, 0x42);
        final transport = StubTransport(myPeerId: peerId);
        expect(transport.myPeerId, equals(peerId));
        transport.dispose();
      });
    });

    group('default mode (no loopback)', () {
      late StubTransport transport;

      setUp(() {
        transport = StubTransport(myPeerId: Uint8List(32));
      });

      tearDown(() {
        transport.dispose();
      });

      test('broadcastPacket does not emit to onPacketReceived', () async {
        final packet = _buildChatPacket('silent');
        final received = <FluxonPacket>[];
        final sub = transport.onPacketReceived.listen(received.add);

        await transport.broadcastPacket(packet);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, isEmpty);
        await sub.cancel();
      });

      test('sendPacket does not emit to onPacketReceived', () async {
        final packet = _buildChatPacket('silent');
        final received = <FluxonPacket>[];
        final sub = transport.onPacketReceived.listen(received.add);

        final result = await transport.sendPacket(packet, Uint8List(32));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(result, isTrue);
        expect(received, isEmpty);
        await sub.cancel();
      });

      test('sendPacket returns true (no-op success)', () async {
        final packet = _buildChatPacket('test');
        final result = await transport.sendPacket(packet, Uint8List(32));
        expect(result, isTrue);
      });
    });

    group('loopback mode', () {
      late StubTransport transport;

      setUp(() {
        transport = StubTransport(
          myPeerId: Uint8List(32),
          loopback: true,
        );
      });

      tearDown(() {
        transport.dispose();
      });

      test('loopback defaults to false', () {
        final t = StubTransport(myPeerId: Uint8List(32));
        expect(t.loopback, isFalse);
        t.dispose();
      });

      test('broadcastPacket echoes packet back to onPacketReceived', () async {
        final packet = _buildChatPacket('echo test');
        final future = transport.onPacketReceived.first;

        await transport.broadcastPacket(packet);

        final received = await future;
        expect(received.type, equals(MessageType.chat));
        expect(
          BinaryProtocol.decodeChatPayload(received.payload),
          equals('echo test'),
        );
      });

      test('sendPacket echoes packet back to onPacketReceived', () async {
        final packet = _buildChatPacket('send echo');
        final future = transport.onPacketReceived.first;

        await transport.sendPacket(packet, Uint8List(32));

        final received = await future;
        expect(
          BinaryProtocol.decodeChatPayload(received.payload),
          equals('send echo'),
        );
      });

      test('multiple broadcasts arrive in order', () async {
        final received = <FluxonPacket>[];
        final sub = transport.onPacketReceived.listen(received.add);

        await transport.broadcastPacket(_buildChatPacket('one', senderByte: 0x01));
        await transport.broadcastPacket(_buildChatPacket('two', senderByte: 0x02));
        await transport.broadcastPacket(_buildChatPacket('three', senderByte: 0x03));

        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, hasLength(3));
        expect(BinaryProtocol.decodeChatPayload(received[0].payload), equals('one'));
        expect(BinaryProtocol.decodeChatPayload(received[1].payload), equals('two'));
        expect(BinaryProtocol.decodeChatPayload(received[2].payload), equals('three'));
        await sub.cancel();
      });
    });

    group('simulateIncomingPacket', () {
      late StubTransport transport;

      setUp(() {
        transport = StubTransport(myPeerId: Uint8List(32));
      });

      tearDown(() {
        transport.dispose();
      });

      test('injects packet into onPacketReceived stream', () async {
        final packet = _buildChatPacket('injected');
        final future = transport.onPacketReceived.first;

        transport.simulateIncomingPacket(packet);

        final received = await future;
        expect(
          BinaryProtocol.decodeChatPayload(received.payload),
          equals('injected'),
        );
      });

      test('works regardless of loopback setting', () async {
        // loopback=false but simulateIncomingPacket should still work
        final packet = _buildChatPacket('always works');
        final future = transport.onPacketReceived.first;

        transport.simulateIncomingPacket(packet);

        final received = await future;
        expect(
          BinaryProtocol.decodeChatPayload(received.payload),
          equals('always works'),
        );
      });

      test('multiple simulated packets arrive in order', () async {
        final received = <FluxonPacket>[];
        final sub = transport.onPacketReceived.listen(received.add);

        transport.simulateIncomingPacket(_buildChatPacket('a', senderByte: 0x01));
        transport.simulateIncomingPacket(_buildChatPacket('b', senderByte: 0x02));
        transport.simulateIncomingPacket(_buildChatPacket('c', senderByte: 0x03));

        await Future.delayed(const Duration(milliseconds: 50));

        expect(received, hasLength(3));
        expect(BinaryProtocol.decodeChatPayload(received[0].payload), equals('a'));
        expect(BinaryProtocol.decodeChatPayload(received[1].payload), equals('b'));
        expect(BinaryProtocol.decodeChatPayload(received[2].payload), equals('c'));
        await sub.cancel();
      });

      test('preserves packet fields exactly', () async {
        final sourceId = Uint8List(32)..fillRange(0, 32, 0xFF);
        final packet = BinaryProtocol.buildPacket(
          type: MessageType.emergencyAlert,
          sourceId: sourceId,
          payload: BinaryProtocol.encodeEmergencyPayload(
            alertType: 1,
            latitude: 37.7749,
            longitude: -122.4194,
            message: 'SOS',
          ),
          ttl: 3,
        );

        final future = transport.onPacketReceived.first;
        transport.simulateIncomingPacket(packet);

        final received = await future;
        expect(received.type, equals(MessageType.emergencyAlert));
        expect(received.ttl, equals(3));
        expect(received.sourceId, equals(sourceId));
      });
    });

    group('connectedPeers', () {
      test('connectedPeers stream exists but emits nothing by default', () async {
        final transport = StubTransport(myPeerId: Uint8List(32));
        final completer = Completer<void>();
        final sub = transport.connectedPeers.listen((_) {
          completer.complete();
        });

        await Future.delayed(const Duration(milliseconds: 50));
        expect(completer.isCompleted, isFalse);

        await sub.cancel();
        transport.dispose();
      });
    });
  });
}
