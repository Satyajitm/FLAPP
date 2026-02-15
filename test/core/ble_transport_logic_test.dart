import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/mesh/deduplicator.dart';
import 'package:fluxon_app/core/protocol/binary_protocol.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';
import 'package:fluxon_app/core/protocol/packet.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/core/transport/transport.dart';
import 'package:fluxon_app/core/transport/transport_config.dart';

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

/// Mirrors BleTransport._handleIncomingData logic for testability.
///
/// Tries decode with signature first, falls back to without.
/// Runs deduplication. Emits valid packets to the controller.
FluxonPacket? handleIncomingData(
  Uint8List data,
  MessageDeduplicator deduplicator,
) {
  var packet = FluxonPacket.decode(data, hasSignature: true);
  packet ??= FluxonPacket.decode(data, hasSignature: false);
  if (packet == null) return null;
  if (deduplicator.isDuplicate(packet.packetId)) return null;
  return packet;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('BleTransport._handleIncomingData logic', () {
    late MessageDeduplicator deduplicator;

    setUp(() {
      deduplicator = MessageDeduplicator(
        maxAge: const Duration(seconds: 300),
        maxCount: 1024,
      );
    });

    group('decode fallback (with/without signature)', () {
      test('decodes unsigned packet via fallback', () {
        final packet = _buildChatPacket('hello');
        final encoded = packet.encode(); // no signature

        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNotNull);
        expect(result!.type, equals(MessageType.chat));
        expect(
          BinaryProtocol.decodeChatPayload(result.payload),
          equals('hello'),
        );
      });

      test('decodes signed packet directly', () {
        final packet = _buildChatPacket('signed msg');
        final sig = Uint8List(64)..fillRange(0, 64, 0xEE);
        final signed = packet.withSignature(sig);
        final encoded = signed.encodeWithSignature();

        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNotNull);
        expect(result!.signature, isNotNull);
        expect(result.signature, equals(sig));
      });

      test('returns null for garbage data', () {
        final garbage = Uint8List.fromList([0xFF, 0x01, 0x02, 0x03]);
        final result = handleIncomingData(garbage, deduplicator);
        expect(result, isNull);
      });

      test('returns null for empty data', () {
        final result = handleIncomingData(Uint8List(0), deduplicator);
        expect(result, isNull);
      });

      test('returns null for data with invalid version', () {
        final packet = _buildChatPacket('test');
        final encoded = packet.encode();
        encoded[0] = 99; // corrupt version byte
        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNull);
      });

      test('returns null for data with invalid message type', () {
        final packet = _buildChatPacket('test');
        final encoded = packet.encode();
        encoded[1] = 0xFF; // invalid message type
        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNull);
      });
    });

    group('deduplication', () {
      test('first packet is accepted', () {
        final packet = _buildChatPacket('first');
        final encoded = packet.encode();
        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNotNull);
      });

      test('duplicate packet is rejected', () {
        final packet = _buildChatPacket('dup');
        final encoded = packet.encode();

        final first = handleIncomingData(encoded, deduplicator);
        expect(first, isNotNull);

        final second = handleIncomingData(encoded, deduplicator);
        expect(second, isNull, reason: 'Duplicate should be rejected');
      });

      test('different packets are both accepted', () {
        final packet1 = _buildChatPacket('msg1', senderByte: 0x01);
        final packet2 = _buildChatPacket('msg2', senderByte: 0x02);

        final result1 = handleIncomingData(packet1.encode(), deduplicator);
        final result2 = handleIncomingData(packet2.encode(), deduplicator);

        expect(result1, isNotNull);
        expect(result2, isNotNull);
      });

      test('same content from same sender with same timestamp is deduplicated', () {
        // Build two identical packets (same sourceId, timestamp, type)
        final packet = _buildChatPacket('same');
        final encoded = packet.encode();

        final first = handleIncomingData(encoded, deduplicator);
        final second = handleIncomingData(encoded, deduplicator);

        expect(first, isNotNull);
        expect(second, isNull);
      });
    });

    group('all message types decode correctly', () {
      test('location update packet', () {
        final payload = BinaryProtocol.encodeLocationPayload(
          latitude: 37.7749,
          longitude: -122.4194,
          accuracy: 5.0,
        );
        final packet = BinaryProtocol.buildPacket(
          type: MessageType.locationUpdate,
          sourceId: Uint8List(32)..fillRange(0, 32, 0xBB),
          payload: payload,
        );
        final encoded = packet.encode();
        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNotNull);
        expect(result!.type, equals(MessageType.locationUpdate));

        final loc = BinaryProtocol.decodeLocationPayload(result.payload);
        expect(loc, isNotNull);
        expect(loc!.latitude, closeTo(37.7749, 0.001));
        expect(loc.longitude, closeTo(-122.4194, 0.001));
      });

      test('emergency alert packet', () {
        final payload = BinaryProtocol.encodeEmergencyPayload(
          alertType: 1,
          latitude: 40.7128,
          longitude: -74.0060,
          message: 'Help!',
        );
        final packet = BinaryProtocol.buildPacket(
          type: MessageType.emergencyAlert,
          sourceId: Uint8List(32)..fillRange(0, 32, 0xCC),
          payload: payload,
        );
        final encoded = packet.encode();
        final result = handleIncomingData(encoded, deduplicator);
        expect(result, isNotNull);
        expect(result!.type, equals(MessageType.emergencyAlert));

        final emergency = BinaryProtocol.decodeEmergencyPayload(result.payload);
        expect(emergency, isNotNull);
        expect(emergency!.message, equals('Help!'));
      });
    });
  });

  group('BleTransport._connectingDevices guard logic', () {
    // Tests the concurrent connection prevention pattern used in BleTransport.
    // We simulate the guard using a Set<String>, mirroring the implementation.
    late Set<String> connectedDevices;
    late Set<String> connectingDevices;
    late int maxConnections;
    late List<String> connectionAttempts;

    setUp(() {
      connectedDevices = {};
      connectingDevices = {};
      maxConnections = 7;
      connectionAttempts = [];
    });

    /// Simulates _handleDiscoveredDevice guard logic.
    bool shouldAttemptConnection(String deviceId) {
      if (connectedDevices.contains(deviceId)) return false;
      if (connectingDevices.contains(deviceId)) return false;
      if (connectedDevices.length >= maxConnections) return false;
      connectingDevices.add(deviceId);
      connectionAttempts.add(deviceId);
      return true;
    }

    void completeConnection(String deviceId) {
      connectingDevices.remove(deviceId);
      connectedDevices.add(deviceId);
    }

    void failConnection(String deviceId) {
      connectingDevices.remove(deviceId);
    }

    test('first attempt to a device is allowed', () {
      expect(shouldAttemptConnection('device-A'), isTrue);
      expect(connectingDevices, contains('device-A'));
    });

    test('concurrent attempt to same device is blocked', () {
      shouldAttemptConnection('device-A');
      expect(shouldAttemptConnection('device-A'), isFalse,
          reason: 'Already in connectingDevices');
      expect(connectionAttempts, hasLength(1));
    });

    test('already-connected device is blocked', () {
      shouldAttemptConnection('device-A');
      completeConnection('device-A');

      expect(shouldAttemptConnection('device-A'), isFalse,
          reason: 'Already in connectedDevices');
    });

    test('max connections limit is enforced', () {
      for (var i = 0; i < maxConnections; i++) {
        shouldAttemptConnection('device-$i');
        completeConnection('device-$i');
      }

      expect(shouldAttemptConnection('device-extra'), isFalse,
          reason: 'Max connections reached');
    });

    test('failed connection allows retry', () {
      shouldAttemptConnection('device-A');
      failConnection('device-A');

      expect(shouldAttemptConnection('device-A'), isTrue,
          reason: 'After failure, device should be retryable');
    });

    test('different devices can connect concurrently', () {
      expect(shouldAttemptConnection('device-A'), isTrue);
      expect(shouldAttemptConnection('device-B'), isTrue);
      expect(shouldAttemptConnection('device-C'), isTrue);
      expect(connectingDevices, hasLength(3));
    });

    test('completed connection frees connecting slot', () {
      shouldAttemptConnection('device-A');
      expect(connectingDevices, contains('device-A'));

      completeConnection('device-A');
      expect(connectingDevices, isEmpty);
      expect(connectedDevices, contains('device-A'));
    });
  });

  group('BleTransport scan filter logic', () {
    // Tests the Fluxon device detection criteria used in _startScanning.
    bool isFluxonDevice({
      List<String> serviceUuids = const [],
      String platformName = '',
      String advName = '',
    }) {
      const fluxonServiceUuid = 'F1DF0001-1234-5678-9ABC-DEF012345678';
      final hasService = serviceUuids.any(
        (u) => u.toUpperCase() == fluxonServiceUuid.toUpperCase(),
      );
      final hasName = platformName.toLowerCase().contains('fluxon') ||
          advName.toLowerCase().contains('fluxon');
      return hasService || hasName;
    }

    test('matches by service UUID', () {
      expect(
        isFluxonDevice(
          serviceUuids: ['F1DF0001-1234-5678-9ABC-DEF012345678'],
        ),
        isTrue,
      );
    });

    test('matches by service UUID case-insensitive', () {
      expect(
        isFluxonDevice(
          serviceUuids: ['f1df0001-1234-5678-9abc-def012345678'],
        ),
        isTrue,
      );
    });

    test('matches by platform name containing "Fluxon"', () {
      expect(
        isFluxonDevice(platformName: 'Fluxon'),
        isTrue,
      );
    });

    test('matches by platform name case-insensitive', () {
      expect(
        isFluxonDevice(platformName: 'FLUXON Device'),
        isTrue,
      );
    });

    test('matches by advertisement name', () {
      expect(
        isFluxonDevice(advName: 'Fluxon'),
        isTrue,
      );
    });

    test('matches by advertisement name case-insensitive', () {
      expect(
        isFluxonDevice(advName: 'fluxon mesh'),
        isTrue,
      );
    });

    test('rejects device with no matching criteria', () {
      expect(
        isFluxonDevice(
          serviceUuids: ['00001800-0000-1000-8000-00805f9b34fb'],
          platformName: 'Samsung Galaxy',
          advName: '',
        ),
        isFalse,
      );
    });

    test('rejects empty device info', () {
      expect(isFluxonDevice(), isFalse);
    });

    test('matches when service UUID present even with wrong name', () {
      expect(
        isFluxonDevice(
          serviceUuids: ['F1DF0001-1234-5678-9ABC-DEF012345678'],
          platformName: 'Samsung Galaxy',
        ),
        isTrue,
      );
    });

    test('matches when name present even without service UUID', () {
      expect(
        isFluxonDevice(
          serviceUuids: [],
          platformName: 'Fluxon',
        ),
        isTrue,
      );
    });
  });

  group('BleTransport.connectedPeers stream', () {
    test('StubTransport exposes connectedPeers stream', () {
      final transport = StubTransport(myPeerId: Uint8List(32));
      expect(transport.connectedPeers, isA<Stream<List<PeerConnection>>>());
      transport.dispose();
    });

    test('connectedPeers is a broadcast stream', () async {
      final transport = StubTransport(myPeerId: Uint8List(32));
      // Should be able to listen multiple times without error
      final sub1 = transport.connectedPeers.listen((_) {});
      final sub2 = transport.connectedPeers.listen((_) {});
      await sub1.cancel();
      await sub2.cancel();
      transport.dispose();
    });
  });

  group('TransportConfig defaults', () {
    test('default scan interval is 2000ms', () {
      expect(TransportConfig.defaultConfig.scanIntervalMs, equals(2000));
    });

    test('default max connections is 7', () {
      expect(TransportConfig.defaultConfig.maxConnections, equals(7));
    });

    test('default connection timeout is 10000ms', () {
      expect(TransportConfig.defaultConfig.connectionTimeoutMs, equals(10000));
    });

    test('custom config overrides defaults', () {
      const custom = TransportConfig(
        scanIntervalMs: 5000,
        maxConnections: 3,
        connectionTimeoutMs: 5000,
      );
      expect(custom.scanIntervalMs, equals(5000));
      expect(custom.maxConnections, equals(3));
      expect(custom.connectionTimeoutMs, equals(5000));
    });
  });

  group('End-to-end: encode → wire → decode fallback → dedup', () {
    test('unsigned chat packet survives full pipeline', () {
      final deduplicator = MessageDeduplicator();
      final original = _buildChatPacket('e2e test', senderByte: 0x42);

      // Encode (what BleTransport.broadcastPacket does)
      final wire = original.encodeWithSignature(); // no sig → same as encode()

      // Decode with fallback (what _handleIncomingData does)
      final result = handleIncomingData(wire, deduplicator);

      expect(result, isNotNull);
      expect(result!.type, equals(MessageType.chat));
      expect(
        BinaryProtocol.decodeChatPayload(result.payload),
        equals('e2e test'),
      );
      expect(result.sourceId[0], equals(0x42));
    });

    test('signed packet survives full pipeline', () {
      final deduplicator = MessageDeduplicator();
      final original = _buildChatPacket('signed e2e', senderByte: 0x99);
      final sig = Uint8List(64)..fillRange(0, 64, 0xAB);
      final signed = original.withSignature(sig);

      final wire = signed.encodeWithSignature();
      final result = handleIncomingData(wire, deduplicator);

      expect(result, isNotNull);
      expect(
        BinaryProtocol.decodeChatPayload(result!.payload),
        equals('signed e2e'),
      );
      expect(result.signature, equals(sig));
    });

    test('duplicate wire data is rejected on second pass', () {
      final deduplicator = MessageDeduplicator();
      final packet = _buildChatPacket('once only');
      final wire = packet.encode();

      expect(handleIncomingData(wire, deduplicator), isNotNull);
      expect(handleIncomingData(wire, deduplicator), isNull);
    });
  });
}
