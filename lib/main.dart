import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/identity/peer_id.dart';
import 'core/transport/stub_transport.dart';
import 'features/chat/chat_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // TODO: Initialize sodium_libs before app starts:
  //   await SodiumInit.init();
  // TODO: Initialize IdentityManager
  // TODO: Replace stub transport with BleTransport on mobile

  // Generate a random 32-byte peer ID for this session
  final random = Random.secure();
  final peerIdBytes = Uint8List.fromList(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final myPeerId = PeerId(peerIdBytes);

  // Create a stub transport for platforms without BLE
  final transport = StubTransport(myPeerId: peerIdBytes);

  runApp(
    ProviderScope(
      overrides: [
        transportProvider.overrideWithValue(transport),
        myPeerIdProvider.overrideWithValue(myPeerId),
      ],
      child: const FluxonApp(),
    ),
  );
}
