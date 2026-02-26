# FluxonApp — Full Code Analysis Report (5 Security Lenses)

**Date:** 2026-02-26
**Branch:** Major_Security_Fixes
**Scope:** All files in `lib/` — transport, mesh, crypto, protocol, identity, services, features

## Analysis Lenses

| # | Lens | Question |
|---|---|---|
| 1 | Input Validation | Does every input from BLE/network have a length/range check? |
| 2 | Async Error Handling | Does every async operation have error handling? |
| 3 | Resource Disposal | Does every resource (Stream, Timer, Controller) get disposed? |
| 4 | Crash State on Disk | If the app crashes RIGHT HERE, what state is left on disk? |
| 5 | Malicious Peer | Can a malicious peer trigger this code path with crafted data? |

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 7 |
| HIGH | 14 |
| MEDIUM | 16 |
| LOW | 13 |
| **Total** | **50** |

### Lens Distribution

| Lens | Findings |
|---|---|
| 1 — Missing input/length/range check | 14 |
| 2 — Missing async error handling | 24 |
| 3 — Resource not disposed | 11 |
| 4 — Crash leaves bad state on disk | 8 |
| 5 — Malicious peer exploitable | 16 |

---

## CRITICAL (7)

### C1 — `ble_transport.dart:506` — Lens 3, 5 — Stream subscription leak on `char.onValueReceived`

**What is wrong:** The `StreamSubscription` returned by `char.onValueReceived.listen()` is never stored and never cancelled. When the device disconnects, the disconnection handler removes the device from all maps and calls `_noiseSessionManager.removeSession(deviceId)`, but the subscription on `char.onValueReceived` remains live. If the underlying BLE stack reuses the characteristic object, a reconnecting malicious device could deliver data under an already-cleaned-up `deviceId` context with no session state, bypassing the Noise session check (since `hasSession` would return false for a cleaned-up `deviceId`) and slipping through the per-device rate limiter via a fresh `_lastPacketTime` entry. The subscription also leaks memory on every disconnect/reconnect cycle.

**Suggested fix:**
```dart
final sub = char.onValueReceived.listen((data) {
  _handleIncomingData(Uint8List.fromList(data), fromDeviceId: deviceId);
});
// Store sub, and in the disconnection handler:
sub.cancel();
```

---

### C2 — `ble_transport.dart:519` — Lens 3 — Connection state subscription never cancelled

**What is wrong:** The `StreamSubscription` for `result.device.connectionState.listen()` is never stored or cancelled. If a peer connects, disconnects, and reconnects multiple times, multiple overlapping `connectionState` subscriptions accumulate on the same device object. Each one will independently run the cleanup block on disconnect, meaning `_noiseSessionManager.removeSession(deviceId)` and all map removals are called redundantly. A malicious peer that repeatedly connects/disconnects can grow this leaked subscription list unboundedly.

**Suggested fix:**
```dart
StreamSubscription? connStateSub;
connStateSub = result.device.connectionState.listen((state) {
  if (state == BluetoothConnectionState.disconnected) {
    connStateSub?.cancel();
    // ... existing cleanup ...
  }
});
```

---

### C3 — `noise_protocol.dart:480` — Lens 1, 5 — `remoteStaticPublic` set without 32-byte length validation

**What is wrong:** In `readMessage`, when the `s` (static key) token is processed, the decrypted value is assigned directly to `remoteStaticPublic` without validating its length. If `hasCipherKey` is false at decryption time (possible in degenerate implementations), `decryptAndHash` returns the raw ciphertext unmodified, and there is zero length enforcement on the result. `NoiseSessionManager.processHandshakeMessage` validates `remoteSigningKey.length == 32`, but there is no equivalent check that `remotePubKey` (the `remoteStaticPublic` value) is exactly 32 bytes before it is stored and later used as an X25519 public key in `_performDH`. Passing a non-32-byte blob to `sodium.crypto.scalarmult` will trigger a libsodium assertion crash.

**Suggested fix:**
```dart
// noise_protocol.dart ~line 480, after decryption:
if (decrypted.length != 32) throw const NoiseException(NoiseError.invalidPublicKey);
remoteStaticPublic = decrypted;
```
And in `noise_session_manager.dart ~line 181`:
```dart
if (remotePubKey.length != 32) { state.dispose(); throw ...; }
```

---

### C4 — `mesh_service.dart:155` — Lens 2 — Stream subscriptions missing `onError` — BLE error kills mesh silently

**What is wrong:** `_packetSub` and `_peersSub` are created with no `onError` handler. If the underlying `BleTransport` stream emits an error (e.g., BLE hardware failure, platform exception), the error propagates to an unhandled `StreamSubscription` and kills the subscription permanently. After that, `MeshService` receives no further packets from the transport layer — the mesh becomes silently deaf with no recovery path.

**Suggested fix:**
```dart
_packetSub = _rawTransport.onPacketReceived.listen(
  _onPacketReceived,
  onError: (e) => SecureLogger.warning('Transport packet stream error: $e', category: _cat),
);
_peersSub = _rawTransport.connectedPeers.listen(
  _onPeersChanged,
  onError: (e) => SecureLogger.warning('Transport peers stream error: $e', category: _cat),
);
```

---

### C5 — `device_terminal_controller.dart:81` — Lens 1, 5 — No cap on terminal messages — rogue BLE device causes OOM

**What is wrong:** Every byte chunk received from the BLE hardware device is appended as a new `TerminalMessage` into `state.messages` with no cap. The chat and emergency controllers both cap their lists at 200 entries — this controller has no equivalent guard. A rogue device sending one-byte BLE notifications (~133/sec) can crash the app within minutes.

**Suggested fix:**
```dart
final capped = [...state.messages, msg];
state = state.copyWith(
  messages: capped.length > 500 ? capped.sublist(capped.length - 500) : capped,
);
```

---

### C6 — `ble_device_terminal_repository.dart:158` — Lens 1, 5 — No payload size guard before GATT write

**What is wrong:** `send(Uint8List data)` writes the entire buffer to the GATT characteristic with no length check. The BLE spec limits a single GATT write to the negotiated MTU minus 3 bytes (typically 509 bytes). `flutter_blue_plus` does not automatically fragment writes — passing an oversized buffer will either throw an unhandled platform exception or silently truncate. The `sendText` path encodes arbitrary user-typed text as UTF-8 with no length limit.

**Suggested fix:**
```dart
if (data.length > 512) throw ArgumentError('Payload exceeds BLE MTU (512 bytes)');
await char.write(data.toList(), withoutResponse: false);
```

---

### C7 — `group_storage.dart:74` — Lens 2, 4 — `DateTime.parse` uncaught — corrupt storage bricks app startup

**What is wrong:** `DateTime.parse(createdAtStr)` is called with no error handling. `createdAtStr` comes from `flutter_secure_storage` — if corrupted (partial write interrupted by crash, storage bit-flip), `DateTime.parse` throws a `FormatException`. This propagates out of `GroupManager.initialize()` inside `Future.wait(...)` in `main.dart`. A single corrupt timestamp permanently bricks app startup — the user cannot open the app without manually clearing data.

If the app crashes between `_storage.write(key: _groupKeyTag, ...)` and `_storage.write(key: _saltTag, ...)`, storage has an inconsistent snapshot. The null-check case is handled, but corrupt-but-non-null values are not.

**Suggested fix:**
```dart
createdAt: DateTime.tryParse(createdAtStr) ?? DateTime.now(),
```

---

## HIGH (14)

### H1 — `ble_transport.dart:348` — Lens 2 — Scan results stream has no `onError`

**What is wrong:** `_scanSubscription = FlutterBluePlus.scanResults.listen(...)` has no `onError` callback. An error emitted by the BLE scan stream (e.g., platform exception when Bluetooth turns off mid-scan) propagates unhandled and closes the subscription. The app silently stops discovering peers with no user-visible error.

**Suggested fix:**
```dart
_scanSubscription = FlutterBluePlus.scanResults.listen(
  (results) { ... },
  onError: (e) => _log('Scan stream error: $e'),
  cancelOnError: false,
);
```

---

### H2 — `ble_transport.dart:656` — Lens 2, 5 — `_authenticatedPeripheralClients` has no enforced cap

**What is wrong:** `_authenticatedPeripheralClients` is a `Set<String>` with no enforced cap. It is added to every time a handshake completes, and only removed on disconnect or 60-second eviction. A TOCTOU window exists between the `.containsKey` check and the `_peripheralClients[deviceId] = now` write since `setWriteRequestCallback` can fire concurrently, allowing the set to grow beyond `config.maxConnections`.

**Suggested fix:**
```dart
if (_authenticatedPeripheralClients.length > config.maxConnections) {
  _authenticatedPeripheralClients.remove(_authenticatedPeripheralClients.first);
}
```

---

### H3 — `ble_transport.dart:336` — Lens 2 — Bluetooth adapter wait has no timeout

**What is wrong:** `await FlutterBluePlus.adapterState.where((s) => s == BluetoothAdapterState.on).first` has no timeout. If Bluetooth never turns on, this `await` never completes. The app appears frozen with no error.

**Suggested fix:**
```dart
await FlutterBluePlus.adapterState
    .where((s) => s == BluetoothAdapterState.on)
    .first
    .timeout(const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('Bluetooth adapter did not turn on'));
```

---

### H4 — `noise_protocol.dart:532` — Lens 3 — `SecureKey.fromList` for DH private key never disposed

**What is wrong:** `_performDH` creates a `SecureKey` via `SecureKey.fromList(sodium, privateKey)` and passes it directly to `scalarmult`. The `SecureKey` is never disposed. `SecureKey.fromList` allocates libsodium-protected memory, and without `.dispose()`, this secure memory region leaks for every DH operation.

**Suggested fix:**
```dart
final skWrapper = SecureKey.fromList(sodium, privateKey);
try {
  final sharedSecret = sodium.crypto.scalarmult(n: skWrapper, p: publicKey);
  ...
} finally {
  skWrapper.dispose();
}
```

---

### H5 — `gossip_sync.dart:134` — Lens 2 — `sendPacket` in sync loop has no try/catch

**What is wrong:** `handleSyncRequest` calls `await _transport.sendPacket(packet, fromPeerId)` inside a `for` loop with no try/catch. If `sendPacket` throws (BLE write failure, transport closed), the exception propagates out uncaught, remaining sync packets are never sent, and the `rateState.count` is already incremented wastefully.

**Suggested fix:**
```dart
try {
  await _transport.sendPacket(packet, fromPeerId);
} catch (e) {
  SecureLogger.warning('GossipSync: sendPacket failed: $e');
  break;
}
```

---

### H6 — `noise_session_manager.dart:311` — Lens 3 — `removeSession` drops `_PeerState` without disposing

**What is wrong:** `removeSession(String deviceId)` calls `_peers.remove(deviceId)` and discards the returned `_PeerState` without calling `dispose()` on the session or handshake. `NoiseCipherState` SecureKeys (send and receive) are never disposed, leaking libsodium-protected memory.

**Suggested fix:**
```dart
void removeSession(String deviceId) {
  final peer = _peers.remove(deviceId);
  peer?.handshake?.dispose();
  peer?.session?.dispose();
}
```

---

### H7 — `mesh_service.dart:125` — Lens 4 — Bare `catch (_)` on signing silently sends unsigned packets on mobile

**What is wrong:** `sendPacket` and `broadcastPacket` catch all signing exceptions with `catch (_)` and comment "Sodium not available (test/desktop) — send unsigned." On production Android/iOS where sodium IS initialized, a genuine libsodium error (corrupted key, memory pressure) is silently swallowed, and the packet is sent unsigned. Remote peers that have signing keys for this node will drop the unsigned packets. Messages silently fail to deliver.

**Suggested fix:**
```dart
try {
  final sig = Signatures.sign(...);
  outgoing = packet.withSignature(sig);
} on UnsupportedError {
  // Sodium not available on desktop/test — intentional
} catch (e) {
  SecureLogger.warning('Signing failed, aborting send: $e', category: _cat);
  return false;
}
```

---

### H8 — `message_storage_service.dart:176` — Lens 1, 5 — Unbounded `jsonList` deserialization

**What is wrong:** `ChatMessage.fromJson` is called on data loaded from disk with no guard on the size of the deserialized `jsonList`. A malicious actor who gains write access to the documents directory (backup extraction, adb on rooted device) can store a crafted `.bin` file that expands into tens of thousands of entries. On every load this allocates unbounded memory and blocks the event loop.

**Suggested fix:**
```dart
if (jsonList.length > 10000) return [];
```

---

### H9 — `receipt_service.dart:85` — Lens 1, 5 — `_pendingReadReceipts` unbounded

**What is wrong:** `_pendingReadReceipts` grows without bound. A malicious peer sending a large number of distinct group chat messages can cause unbounded map growth. Under the flush-retry path, failed batches do NOT clear the map, so it can only grow. Memory exhaustion vector.

**Suggested fix:**
```dart
if (_pendingReadReceipts.length >= 500) return;
```

---

### H10 — `group_manager.dart:161` — Lens 2 — `unawaited(deleteGroup())` leaves group key on disk

**What is wrong:** `leaveGroup()` calls `unawaited(_groupStorage.deleteGroup())`. If `deleteGroup()` throws (secure storage I/O error), the error is silently swallowed. `_activeGroup` and cipher cache are cleared in memory, but the group key survives on disk. On next app start, `initialize()` reloads the group, putting the user back in a group they explicitly left. The user believes they left, but stored key still allows decryption.

**Suggested fix:**
```dart
Future<void> leaveGroup() async {
  _activeGroup = null;
  _cipher.clearCache();
  try { await _groupStorage.deleteGroup(); } catch (_) {}
}
```

---

### H11 — `device_services.dart:40-54` — Lens 2 — `getCurrentPosition()` has no error handling

**What is wrong:** `GeolocatorGpsService.getCurrentPosition()` calls `Geolocator.getCurrentPosition(...)` with no try/catch. Geolocator throws `LocationServiceDisabledException` when GPS is off, `PermissionDeniedException` when permission is revoked, and a generic `Exception` on iOS in airplane mode. The raw plugin exception propagates to any controller that omits a try/catch.

**Suggested fix:**
```dart
Future<GpsPosition> getCurrentPosition() async {
  try {
    final position = await Geolocator.getCurrentPosition(...);
    return GpsPosition(...);
  } catch (e) {
    throw LocationException('GPS unavailable: $e');
  }
}
```

---

### H12 — `group_cipher.dart:238` — Lens 2, 5 — `Isolate.run` in `deriveAsync` has no error containment

**What is wrong:** `deriveAsync()` calls `Isolate.run(() => _deriveInIsolate(...))` with no try/catch. `_deriveInIsolate` calls `SodiumSumoInit.init()` which can fail if sodium libraries are missing or if the isolate runs out of memory during Argon2id. A malicious actor triggering repeated group join attempts (fabricated `groupJoinResponse` packets) can cause repeated `Isolate.run` calls — each failed isolate is a resource leak.

**Suggested fix:**
```dart
final result = await Isolate.run(() => _deriveInIsolate((passphrase, salt)))
    .catchError((_) => throw StateError('Key derivation failed'));
```

---

### H13 — `chat_controller.dart:71` + `message_model.dart:98` — Lens 2, 4 — `fromJson` throws on corrupt data

**What is wrong:** `ChatMessage.fromJson` performs direct type-casting with `as String`, `DateTime.parse(...)`, `PeerId.fromHex(...)`, `MessageStatus.values.byName(...)`. Any corrupted stored JSON throws `TypeError`, `FormatException`, or `ArgumentError`. `_loadPersistedMessages` has no try/catch, so a single corrupted message discards the entire chat history. If the app crashes during `saveMessages`, the JSON file can be partially written, permanently losing all messages.

**Suggested fix for `fromJson`:**
```dart
static ChatMessage? tryFromJson(Map<String, dynamic> json) {
  try { return ChatMessage.fromJson(json); } catch (_) { return null; }
}
```

**Suggested fix for `_loadPersistedMessages`:**
```dart
try {
  final saved = await _storageService.loadMessages(_groupId);
  // ...
} catch (_) { /* graceful degradation */ }
```

---

### H14 — `emergency_controller.dart:126` — Lens 2 — No `onError` on alert stream — SOS alerts silently dropped

**What is wrong:** The subscription on `_repository.onAlertReceived` has no `onError` callback. Emergency alerts are the highest-priority message type. A stream error silently cancels this subscription (Dart's default), meaning all subsequent SOS alerts from the mesh are dropped without any indication to the user.

**Suggested fix:**
```dart
_alertSub = _repository.onAlertReceived.listen(
  (alert) { ... },
  onError: (Object e) => SecureLogger.warning('EmergencyController: alert stream error: $e'),
  cancelOnError: false,
);
```

---

## MEDIUM (16)

### M1 — `ble_transport.dart:717` — Lens 1 — Min packet size check too low

**What is wrong:** `if (data.isEmpty || data.length > 4096)` allows any data between 1 and 141 bytes through. Minimum valid packet is 78 (header) + 64 (signature) = 142 bytes. `FluxonPacket.decode` handles this by returning null, but the global and per-device rate limiters are consumed by sub-minimum-size packets. A malicious peer sending 1-byte packets exhausts the 100 packets/sec global rate limit with pure garbage.

**Suggested fix:**
```dart
if (data.length < 78 || data.length > 4096) {
```

---

### M2 — `ble_transport.dart:505` — Lens 2 — `setNotifyValue` failure leaves stale entry

**What is wrong:** If `setNotifyValue` throws, the outer try/catch logs the error, but the device is not explicitly disconnected. The `_peerCharacteristics` entry (set before `setNotifyValue`) remains, so a stale entry exists for a device not in `_connectedDevices`, causing null characteristic write attempts in `broadcastPacket`.

**Suggested fix:**
```dart
} catch (e) {
  _log('ERROR connecting: $e');
  try { await result.device.disconnect(); } catch (_) {}
} finally {
```

---

### M3 — `stub_transport.dart:47` — Lens 3 — `stopServices()` doesn't close stream controllers

**What is wrong:** `dispose()` closes both controllers, but `stopServices()` (called by `MeshService` and `main.dart` during shutdown) does not. The `Transport` abstract class does not define `dispose()`, so callers using the interface have no way to close controllers.

**Suggested fix:** Move controller-closing into `stopServices()`, or add `dispose()` to `Transport`.

---

### M4 — `ble_transport.dart:155` — Lens 4 — Partial startup failure leaves advertising running

**What is wrong:** `_running = true` is set before `Future.wait([_startPeripheral(), _startCentral()])`. If `_startCentral()` throws (e.g., location permission denied), the exception propagates but `_running` remains `true` and peripheral is advertising. Timers are running. No cleanup happens.

**Suggested fix:**
```dart
try {
  await Future.wait([_startPeripheral(), _startCentral()]);
} catch (e) {
  await stopServices();
  rethrow;
}
```

---

### M5 — `ble_transport.dart:887` — Lens 5 — Peer ID→device mapping overwritten on handshake

**What is wrong:** `_peerHexToDevice[remotePeerIdHex] = fromDeviceId` has no check for existing mapping. An attacker who eavesdrops Noise XX messages (public key transmitted in clear) and completes a handshake from a different BLE device ID will overwrite the mapping, redirecting future `sendPacket` calls to the attacker. The overwrite happens before Ed25519 check path since `_handleHandshakePacket` runs first.

**Suggested fix:**
```dart
if (!_peerHexToDevice.containsKey(remotePeerIdHex) ||
    _peerHexToDevice[remotePeerIdHex] == fromDeviceId) {
  _deviceToPeerHex[fromDeviceId] = remotePeerIdHex;
  _peerHexToDevice[remotePeerIdHex] = fromDeviceId;
}
```

---

### M6 — `message_storage_service.dart:238` — Lens 4 — Non-atomic file write

**What is wrong:** `_writeEncrypted` calls `file.writeAsBytes(encrypted, flush: true)` which does truncate-then-write. If killed between truncate and final write, the file is left partially written or zero-byte. Messages silently vanish on next launch.

**Suggested fix:**
```dart
final tmp = File('${file.path}.tmp');
await tmp.writeAsBytes(encrypted, flush: true);
await tmp.rename(file.path);
```

---

### M7 — `receipt_service.dart:178` — Lens 1, 5 — No `sourceId` length validation

**What is wrong:** `_handleIncomingReceipt` does not validate `packet.sourceId.length` before constructing `PeerId(packet.sourceId)`. A crafted packet with a non-32-byte `sourceId` causes a runtime error.

**Suggested fix:**
```dart
if (packet.sourceId.length != 32) return;
```

---

### M8 — `receipt_service.dart:146` — Lens 2 — Transport calls not wrapped in try/catch

**What is wrong:** `_sendReceipt` and `_sendBatchReceipts` call `_transport.broadcastPacket`/`sendPacket` without try/catch. A BLE write failure propagates an unhandled exception that silently kills receipt sending.

**Suggested fix:**
```dart
try { await _transport.broadcastPacket(packet); } catch (e) {
  SecureLogger.warning('ReceiptService: send failed: $e');
}
```

---

### M9 — `mesh_service.dart:386` — Lens 2 — `broadcastPacket` in relay has no error handling

**What is wrong:** `_maybeRelay` calls `await _rawTransport.broadcastPacket(relayed)` with no try/catch. Called as fire-and-forget from `_onPacketReceived`, the rejected Future is unhandled. If `broadcastPacket` throws synchronously before the first `await`, it's an unhandled error in the stream listener.

**Suggested fix:**
```dart
try {
  await _rawTransport.broadcastPacket(relayed);
} catch (e) {
  SecureLogger.warning('Relay broadcast failed: $e', category: _cat);
}
```

---

### M10 — `keys.dart:91` — Lens 4 — Corrupted storage value causes crash loop

**What is wrong:** If `_decodeStoredKey` succeeds for `privateRaw` but throws `FormatException` for `publicRaw` (partially corrupted storage), the error propagates uncaught from `loadStaticKeyPair`. `IdentityManager.initialize()` in `main.dart` via `Future.wait` crashes, causing app initialization failure.

**Suggested fix:**
```dart
Future<({Uint8List privateKey, Uint8List publicKey})?> loadStaticKeyPair() async {
  try {
    // existing body
  } catch (e) {
    SecureLogger.warning('Key load failed, will regenerate: $e');
    return null;
  }
}
```

---

### M11 — `group_storage.dart:106` — Lens 5 — `base64Decode` throws uncaught `FormatException`

**What is wrong:** `_decodeBytes()` calls `base64Decode(s)` when the string doesn't match hex heuristic. Invalid input throws `FormatException`, propagating uncaught from `loadGroup()` and crashing startup.

**Suggested fix:**
```dart
static Uint8List? _decodeBytes(String s) {
  try {
    if (...hex check...) return ...hex decode...;
    return base64Decode(s);
  } on FormatException {
    return null;
  }
}
```

---

### M12 — `binary_protocol.dart:195` — Lens 1 — `encodeDiscoveryPayload` no neighbor cap

**What is wrong:** `neighbors.length` directly sets `buffer[0]` (a Uint8). A list longer than 255 entries causes silent integer overflow — `buffer[0] = 256` wraps to `0`, producing a garbled payload indistinguishable from a zero-neighbor announcement. The cap lives in the caller (`mesh_service.dart`), not the encoder.

**Suggested fix:**
```dart
final capped = neighbors.sublist(0, neighbors.length.clamp(0, 10));
buffer[0] = capped.length;
```

---

### M13 — `identity_manager.dart:139` — Lens 5 — `_loadTrustedPeers` unbounded iteration

**What is wrong:** `_loadTrustedPeers()` iterates over the full persisted list with no count cap. The `_maxTrustedPeers = 500` cap is enforced during `trustPeer()`, but not at load time. An attacker with write access to `trusted_peers_v1` storage key can force 10,000+ iterations at startup.

**Suggested fix:**
```dart
for (final hex in hexList.take(_maxTrustedPeers)) { ... }
```

---

### M14 — `group_cipher.dart:172` — Lens 5 — `_derivationCache` unbounded

**What is wrong:** The `_derivationCache` map has no bound. Repeated `createGroup`/`joinGroup` calls with unique salts grow the cache without limit — each entry holds 32 bytes of key material.

**Suggested fix:**
```dart
if (_derivationCache.length >= 4) {
  _derivationCache.remove(_derivationCache.keys.first);
}
```

---

### M15 — `join_group_screen.dart:142` — Lens 1, 5 — QR payload not length-capped

**What is wrong:** Raw QR payload from `MobileScanner` is processed without length check. QR version 40 can hold ~4,296 bytes. An unbounded string is placed into `_joinCodeController.text` before `_isValidCode` is applied, potentially causing layout jank or OOM.

**Suggested fix:**
```dart
if (raw.length > 256) return;
```

---

### M16 — `chat_controller.dart:160` — Lens 4 — Receipt save uses `''` as group ID when null

**What is wrong:** When `_groupId` is null, `saveMessages('', state.messages)` writes to a phantom group on disk that is never read back. Over time orphaned files accumulate, wasting disk space. Receipt ticks are not persisted to the correct group.

**Suggested fix:**
```dart
if (_groupId != null) await _storageService?.saveMessages(_groupId, state.messages);
```

---

## LOW (13)

### L1 — `ble_transport.dart:820` — Lens 5 — Ed25519 verification skipped when signing key not cached

**What is wrong:** A packet with a non-null signature but whose signing key is not yet cached (race: packet arrives just before handshake completion) silently passes without verification. A forged signature arriving in this window is accepted.

**Suggested fix:**
```dart
if (peerSigningKey == null) {
  _log('No signing key for $fromDeviceId — dropping signed packet');
  return;
}
```

---

### L2 — `ble_transport.dart:696` — Lens 5 — `updateCharacteristic` broadcasts to all GATT subscribers

**What is wrong:** The peripheral broadcast loop iterates `authenticatedPeripheral` and builds per-device Noise-encrypted `sendData`, but `BlePeripheral.updateCharacteristic` sends to ALL GATT subscribers, not the specific target. Each device receives N-1 undecryptable packets per broadcast. Functionally incorrect and wasteful.

**Suggested fix:** Use per-device targeting if `ble_peripheral` supports a `deviceId` parameter, otherwise requires per-peer GATT channels.

---

### L3 — `notification_sound.dart:27` — Lens 3 — Concurrent `play()` calls race on `_cachedPath`

**What is wrong:** `_ensureToneFile` has no concurrency guard. Two concurrent calls both pass the null check and write the file simultaneously. Benign (deterministic bytes) but wasted I/O.

**Suggested fix:** Use a `Completer<String>?` as an in-flight guard.

---

### L4 — `foreground_service_manager.dart:74` — Lens 2 — `startService`/`stopService` unguarded

**What is wrong:** `FlutterForegroundTask.startService`/`stopService` can throw `PlatformException` (Android 14+ `FOREGROUND_SERVICE_CONNECTED_DEVICE` permission). Unhandled, this crashes the startup sequence.

**Suggested fix:**
```dart
try { await FlutterForegroundTask.startService(...); } catch (e) {
  SecureLogger.warning('ForegroundServiceManager: start failed: $e');
}
```

---

### L5 — `device_services.dart:69` — Lens 2 — `ensureLocationPermission` returns stale `true`

**What is wrong:** If the user revokes location permission via OS settings mid-session, subsequent calls return the cached result without re-checking, leading to `PermissionDeniedException` from `getCurrentPosition()`.

**Suggested fix:** Always re-check via `Geolocator.checkPermission()` before returning.

---

### L6 — `peer_id.dart:15` — Lens 1 — `assert` stripped in release builds

**What is wrong:** `PeerId` constructor asserts `bytes.length == 32`, but `assert` is compiled out in release mode. Non-32-byte input silently produces an invalid `PeerId`.

**Suggested fix:**
```dart
PeerId(this.bytes) : _hashCode = ... {
  if (bytes.length != 32) throw ArgumentError('PeerId requires 32 bytes');
}
```

---

### L7 — `noise_session_manager.dart:118` — Lens 5 — Global rate limit incremented before LRU insertion

**What is wrong:** The global handshake rate count is incremented BEFORE checking per-device limits. A flood from many device IDs exhausts global budget AND triggers `_stateFor` for each, inserting up to 500 `_PeerState` objects (~several MB) before eviction kicks in.

**Suggested fix:** Call `_stateFor(deviceId)` only after global rate check passes.

---

### L8 — `location_controller.dart:66` — Lens 2 — No `onError` on location stream

**What is wrong:** `_locationSub` has no `onError` callback. All other repository stream subscriptions have error handlers; this is a gap.

**Suggested fix:**
```dart
_locationSub = _repository.onLocationReceived.listen(
  (update) { ... },
  onError: (Object e) => SecureLogger.warning('LocationController: stream error: $e'),
);
```

---

### L9 — `device_terminal_controller.dart:64,73` — Lens 2 — No `onError` on status/data streams

**What is wrong:** Neither `_statusSub` nor `_dataSub` has an `onError` callback. A BLE GATT error terminates the subscription silently. The UI shows stale `connected` status permanently.

**Suggested fix:**
```dart
_statusSub = _repository.onConnectionStatusChanged.listen(
  (status) { ... },
  onError: (_) => state = state.copyWith(connectionStatus: DeviceConnectionStatus.disconnected),
);
```

---

### L10 — `ble_device_terminal_repository.dart:82` — Lens 2, 3 — No dispose guard across async gap

**What is wrong:** `connect()` is a long-running async operation (10s+ across multiple awaits). If the user navigates away during connection, `dispose()` closes `_statusController`. Subsequent `_statusController.add(...)` throws `StateError: Cannot add to a closed StreamController`.

**Suggested fix:**
```dart
if (_disposed) return;
await device.requestMtu(512);
if (_disposed) return;
```

---

### L11 — `device_terminal_controller.dart:124` — Lens 1, 5 — No input length limit on `sendText`

**What is wrong:** `sendText` accepts any-length String, encodes to UTF-8, and calls `_send(data)` with no cap. Multi-KB paste exceeds BLE MTU and fails silently.

**Suggested fix:**
```dart
if (data.length > 512) return;
```

---

### L12 — `create_group_screen.dart:44` — Lens 2 — `_isCreating` never reset on success

**What is wrong:** In the success branch, `_isCreating` is never reset to `false`. If the user navigates back, the create button is permanently disabled.

**Suggested fix:**
```dart
if (mounted) setState(() => _isCreating = false);
```

---

### L13 — `device_terminal_controller.dart:91` — Lens 3 — Scan subscription cancellation race

**What is wrong:** `startScan()` cancels and replaces `_scanSub` before calling `_repository.startScan()`. If `FlutterBluePlus.startScan` throws (Bluetooth off), the repository subscription is left listening to old scan results.

**Suggested fix:**
```dart
await _repository.stopScan();
_scanSub?.cancel();
```

---

## Dominant Pattern: Missing `onError` on Stream Subscriptions

The single most common class of issue across the entire codebase is **stream subscriptions without `onError` handlers** (Lens 2). Affected files:

- `ble_transport.dart` — scan results stream
- `mesh_service.dart` — packet + peers streams
- `location_controller.dart` — location updates stream
- `emergency_controller.dart` — alert stream
- `device_terminal_controller.dart` — status + data streams

In Dart, an error event on a `Stream` that has no `onError` handler in its `.listen()` call will propagate to the uncaught error zone and terminate the subscription. This means **a single BLE stack error can permanently deafen the mesh, drop SOS alerts, or freeze the UI** — all silently.

**Recommendation:** Add `onError` + `cancelOnError: false` to every `.listen()` call on transport/BLE streams.

---

## Recommended Fix Order

1. **CRITICAL C1–C7** — Stream leaks, missing validation, startup bricks
2. **HIGH H1–H14** — Silent failures, resource leaks, error propagation gaps
3. **MEDIUM M1–M16** — Defense-in-depth, atomicity, bounds checks
4. **LOW L1–L13** — Edge cases, UI bugs, minor robustness
