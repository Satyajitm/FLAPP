import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/identity/peer_id.dart';
import 'core/transport/ble_transport.dart';
import 'core/transport/stub_transport.dart';
import 'core/transport/transport.dart';
import 'features/chat/chat_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize sodium_libs before app starts
  await SodiumInit.init();
  
  // Initialize IdentityManager
  final identityManager = IdentityManager();
  await identityManager.initialize();

  // Generate a random 32-byte peer ID for this session
  // TODO: Use identityManager.myPeerId instead of random generation once fully integrated
  final random = Random.secure();
  final peerIdBytes = Uint8List.fromList(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final myPeerId = PeerId(peerIdBytes);

  // Use BleTransport on Android/iOS, StubTransport elsewhere
  final Transport transport;
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    transport = BleTransport(myPeerId: peerIdBytes);
    // TODO: Pass identityManager to BleTransport if needed for auth
  } else {
    transport = StubTransport(myPeerId: peerIdBytes);
  }

  // Launch the UI immediately, then start BLE in the background.
  // This ensures the Flutter engine is running before askBlePermission()
  // shows a native dialog (which requires a rendered activity).
  runApp(
    ProviderScope(
      overrides: [
        transportProvider.overrideWithValue(transport),
        myPeerIdProvider.overrideWithValue(myPeerId),
        // TODO: Add identityManagerProvider
      ],
      child: const FluxonApp(),
    ),
  );

  // Start BLE after the first frame so the permission dialog has
  // a live Activity to attach to.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_startBle(transport));
  });
}

Future<void> _startBle(Transport transport) async {
  try {
    await transport.startServices();
  } catch (_) {
    // BLE failed to start (Bluetooth off, permission denied).
    // BleTransport will retry scanning once the adapter turns on.
  }
}
