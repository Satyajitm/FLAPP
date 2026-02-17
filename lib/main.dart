import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/crypto/sodium_instance.dart';
import 'core/identity/group_manager.dart';
import 'core/identity/identity_manager.dart';
import 'core/providers/group_providers.dart';
import 'core/mesh/mesh_service.dart';
import 'core/transport/ble_transport.dart';
import 'core/transport/stub_transport.dart';
import 'core/transport/transport.dart';
import 'features/chat/chat_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize sodium_libs before any crypto operations
  await initSodium();

  // Initialize identity (loads or creates static key pair)
  final identityManager = IdentityManager();
  await identityManager.initialize();

  // Initialize group manager (restores persisted group if any)
  final groupManager = GroupManager();
  await groupManager.initialize();

  // Derive peer ID from the identity's public key
  final myPeerId = identityManager.myPeerId;
  final myPeerIdBytes = myPeerId.bytes;

  // Use BleTransport on Android/iOS, StubTransport elsewhere
  final Transport rawTransport;
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    rawTransport = BleTransport(
      myPeerId: myPeerIdBytes,
      identityManager: identityManager,
    );
  } else {
    rawTransport = StubTransport(myPeerId: myPeerIdBytes);
  }

  // Wrap with MeshService for multi-hop relay, topology tracking, and gossip
  final transport = MeshService(
    transport: rawTransport,
    myPeerId: myPeerIdBytes,
    identityManager: identityManager,
  );

  // Launch the UI immediately, then start BLE in the background.
  // This ensures the Flutter engine is running before askBlePermission()
  // shows a native dialog (which requires a rendered activity).
  runApp(
    ProviderScope(
      overrides: [
        transportProvider.overrideWithValue(transport),
        myPeerIdProvider.overrideWithValue(myPeerId),
        groupManagerProvider.overrideWithValue(groupManager),
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
