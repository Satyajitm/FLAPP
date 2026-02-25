import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/crypto/sodium_instance.dart';
import 'core/identity/group_manager.dart';
import 'core/identity/identity_manager.dart';
import 'core/identity/user_profile_manager.dart';
import 'core/providers/group_providers.dart';
import 'core/providers/profile_providers.dart';
import 'core/providers/transport_providers.dart';
import 'core/mesh/mesh_service.dart';
import 'core/services/foreground_service_manager.dart';
import 'core/transport/ble_transport.dart';
import 'core/transport/stub_transport.dart';
import 'core/transport/transport.dart';

Future<void> main() async {
  // Must be called before anything else for flutter_foreground_task v9.
  // dart:isolate is not available on web, so guard this call.
  if (!kIsWeb) FlutterForegroundTask.initCommunicationPort();

  WidgetsFlutterBinding.ensureInitialized();

  // Configure the Android foreground service. No-op on iOS/desktop.
  ForegroundServiceManager.initialize();

  // Initialize sodium_libs before any crypto operations
  await initSodium();

  // Initialize identity, groups, and profile in parallel — none depends on another.
  final identityManager = IdentityManager();
  final groupManager = GroupManager();
  final profileManager = UserProfileManager();
  await Future.wait([
    identityManager.initialize(),
    groupManager.initialize(),
    profileManager.initialize().catchError((Object e, StackTrace st) {
      developer.log(
        'UserProfileManager.initialize() failed — display name will be empty',
        name: 'FluxonApp.main',
        error: e,
        stackTrace: st,
      );
    }),
  ]);

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
        userProfileManagerProvider.overrideWithValue(profileManager),
        displayNameProvider.overrideWith((ref) => profileManager.displayName),
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
    // BLE is running — start the foreground service to prevent Android
    // from killing the process when the app is backgrounded.
    await ForegroundServiceManager.start();
  } catch (_) {
    // BLE failed to start (Bluetooth off, permission denied).
    // BleTransport will retry scanning once the adapter turns on.
    // Do not start the foreground service if BLE did not start.
  }
}
