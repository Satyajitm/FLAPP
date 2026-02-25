# FluxonApp — BLE/Bluetooth Layer Security Audit

**Date:** 2026-02-24  
**Scope:** All Bluetooth-related code across transport, crypto, mesh, protocol, and feature layers  
**Methodology:** Manual code review + threat modeling against OWASP BLE, Noise Protocol spec, and mesh networking attack taxonomies

---

## Executive Summary

The FluxonApp BLE layer implements a dual-role (central + peripheral) Bluetooth mesh with **Noise XX** mutual authentication and **ChaCha20-Poly1305** encryption. The implementation shows solid defensive coding in many areas — rate limiting, deduplication, timestamp validation, MTU enforcement, LRU capping, and replay window protection are all present.

However, the audit identified **28 findings** across 4 severity tiers, including **4 critical**, **7 high**, **8 medium**, and **9 low/informational** issues. The most concerning vulnerabilities center around:

1. **Peripheral broadcast data leakage** — packets pushed to GATT server clients are sent unencrypted
2. **Signature bypass window** — unknown peers' packets are accepted provisionally without signatures
3. **Source ID spoofing** — packet `sourceId` is never bound to the authenticated peer identity
4. **Incomplete handshake state cleanup** allowing resource exhaustion

---

## Files Analyzed

| File | Lines | Role |
|------|-------|------|
| `lib/core/transport/ble_transport.dart` | 781 | Central + Peripheral BLE transport |
| `lib/core/crypto/noise_protocol.dart` | 537 | Noise XX handshake + CipherState |
| `lib/core/crypto/noise_session.dart` | 67 | Post-handshake encrypted session |
| `lib/core/crypto/noise_session_manager.dart` | 283 | Per-device session management |
| `lib/core/crypto/signatures.dart` | 73 | Ed25519 signing/verification |
| `lib/core/crypto/keys.dart` | 208 | Key generation + secure storage |
| `lib/core/mesh/mesh_service.dart` | 360 | Mesh relay orchestrator |
| `lib/core/mesh/relay_controller.dart` | 94 | Relay flood control |
| `lib/core/mesh/deduplicator.dart` | 117 | Packet deduplication |
| `lib/core/mesh/topology_tracker.dart` | 199 | Mesh topology + BFS routing |
| `lib/core/mesh/gossip_sync.dart` | 141 | Gossip-based gap filling |
| `lib/core/protocol/packet.dart` | 185 | Wire format encode/decode |
| `lib/core/protocol/binary_protocol.dart` | 329 | Payload codec |
| `lib/core/protocol/message_types.dart` | 58 | Message type enumeration |
| `lib/core/protocol/padding.dart` | 34 | PKCS#7 padding |
| `lib/core/identity/group_manager.dart` | 199 | Group lifecycle |
| `lib/core/identity/group_cipher.dart` | 215 | Group symmetric encryption |
| `lib/core/transport/transport_config.dart` | 72 | Tunable parameters |
| `lib/features/chat/data/mesh_chat_repository.dart` | 172 | Chat over mesh |
| `lib/features/location/data/mesh_location_repository.dart` | 138 | Location over mesh |
| `lib/features/emergency/data/mesh_emergency_repository.dart` | 119 | Emergency alerts over mesh |
| `lib/features/device_terminal/data/ble_device_terminal_repository.dart` | 181 | Hardware device BLE |

---

## CRITICAL Findings

### CRIT-1: Peripheral Broadcast Sends Unencrypted Data to All GATT Clients

**File:** `ble_transport.dart`, lines 578–589  
**CVSS Estimate:** 8.1 (High)

```dart
// Also notify via peripheral (GATT server) to any connected centrals.
final peripheralFuture = () async {
  try {
    await ble_p.BlePeripheral.updateCharacteristic(
      characteristicId: packetCharUuidStr,
      value: data,      // ← UNENCRYPTED plaintext `data`
    );
```

**The Bug:** When `broadcastPacket()` is called, the method encrypts `data` per-peer for central connections (lines 567–569), correctly using each peer's Noise session. However, the **peripheral GATT server update** (line 584) uses the **original unencrypted `data`** — not the per-peer ciphertext.

Any device connected to this phone in the central role receives the raw signed packet with plaintext headers (source ID, packet type, timestamp, TTL) and potentially plaintext payload (if group encryption is not active).

**Exploit Scenario:** An attacker connects as a central to the victim's peripheral. Without completing any Noise handshake, the attacker receives every broadcast packet in cleartext via GATT notifications.

**Remediation:**
- Do NOT send data via the peripheral characteristic to devices that haven't completed a Noise handshake
- Maintain a set of authenticated peripheral clients and encrypt individually per-client, or
- Only enable GATT notifications after the Noise session is established on the peripheral side

---

### CRIT-2: Source ID Spoofing — No Binding Between Authenticated Identity and Packet sourceId

**File:** `ble_transport.dart`, lines 640–688; `mesh_service.dart`, lines 182–236  
**CVSS Estimate:** 8.6 (High)

After a Noise XX handshake completes, the remote peer's static public key is derived and mapped to a peer ID hex. However, **incoming packets' `sourceId` field is never validated against the authenticated identity** of the BLE device that sent them.

```dart
// ble_transport.dart line 687
_log('Valid packet received from ${HexUtils.encode(packet.sourceId)}');
_packetController.add(packet);  // sourceId is the raw field from the packet, NOT verified
```

**The Bug:** An authenticated peer (Device A, peer ID = X) can forge packets with `sourceId = Y` (any other peer's ID). The signature check at line 667–678 only verifies the signature against the signing key of `fromDeviceId`, but the `sourceId` inside the packet can differ from the authenticated peer behind `fromDeviceId`.

**Exploit Scenario:**
1. Attacker connects and completes a legitimate Noise handshake
2. Attacker crafts a packet with `sourceId` set to the victim's peer ID
3. The packet passes signature verification (signed by the attacker's valid key)
4. The mesh layer (`MeshService`) relays this packet, effectively impersonating the victim
5. Chat messages, emergency alerts, and location updates can all be spoofed

**Remediation:**
- After handshake, bind `fromDeviceId → authenticatedPeerIdHex`
- In `_handleIncomingData`, reject any packet whose `sourceId` doesn't match the authenticated peer ID for that BLE connection
- For relayed packets (TTL < original), verify the signature against the originating peer's known signing key

---

### CRIT-3: Provisional Acceptance of Unsigned Packets from Unknown Peers

**File:** `mesh_service.dart`, lines 209–217  
**CVSS Estimate:** 7.5 (High)

```dart
} else {
  // Signing key not yet available — accept provisionally.
  SecureLogger.debug(
    'Packet from unknown peer (no signing key cached) — accepting provisionally',
    category: _cat,
  );
}
```

**The Bug:** When a peer's signing key is not yet cached, all packets from that peer are accepted without **any** signature verification. This creates a race-condition window:

1. Attacker connects but intentionally delays/avoids completing the Noise handshake
2. During this window, all attacker packets are accepted provisionally
3. Attacker can inject arbitrary chat messages, location updates, emergency alerts
4. Once the signing key IS learned, the attacker's window closes — but the damage is done

**Exploit Scenario:** A BLE-adjacent attacker floods unsigned emergency alerts before any handshake completes. All nearby devices display spoofed SOS alerts.

**Remediation:**
- Buffer provisionally accepted packets and validate them retroactively once the signing key arrives
- Or: reject all non-handshake packets from devices without an established Noise session
- At minimum: exclude `emergencyAlert` and `locationUpdate` types from provisional acceptance

---

### CRIT-4: Handshake State Not Disposed on Failure Paths

**File:** `noise_session_manager.dart`, lines 117–202; `noise_protocol.dart`, line 513  
**CVSS Estimate:** 6.5 (Medium-High)

The `NoiseHandshakeState` object holds sensitive ephemeral private keys in Dart heap memory. In `processHandshakeMessage`:

- If the handshake **completes** normally, the state is nulled (line 162/191): `peer.handshake = null;`
- If the handshake **fails** (e.g., invalid message, wrong key, exception), the `handshake` field is left populated with stale key material
- If the handshake **succeeds** but the remote signing key fails validation (e.g., all-zero key), an exception is thrown (lines 152/180) but `peer.handshake` is not cleaned up

**The Bug:** Failed handshakes leave ephemeral private keys in memory indefinitely. Additionally, the `dispose()` method on `NoiseHandshakeState` is never called in normal operation — it's only available for explicit cleanup. The handshake object's ephemeral keys sit in unprotected Dart heap memory.

**Remediation:**
- Wrap `processHandshakeMessage` in try/finally that calls `peer.handshake?.dispose()` and sets `peer.handshake = null` on all failure paths
- Add a timeout mechanism that auto-disposes in-progress handshake states after N seconds
- Consider zeroing ephemeral keys immediately after the DH operations in `writeMessage`/`readMessage`

---

## HIGH Findings

### HIGH-1: Rate Limiter Uses Wall Clock — Trivially Bypassable

**File:** `ble_transport.dart`, lines 608–616  
**CVSS Estimate:** 5.3

```dart
final now = DateTime.now();
final lastTime = _lastPacketTime[fromDeviceId];
if (lastTime != null &&
    now.difference(lastTime).inMilliseconds < _minPacketIntervalMs) {
  _log('Rate limiting $fromDeviceId — dropping packet');
  return;
}
_lastPacketTime[fromDeviceId] = now;
```

**Issues:**
1. The rate limit is **per device ID**, but a BLE device can change its MAC address (most Android devices use random/rotated addresses). An attacker can reconnect with a different device ID and bypass the limit entirely.
2. There is no **total packet rate limit** across all devices — an attacker creating N simultaneous connections gets N × 20 packets/sec.
3. `DateTime.now()` is susceptible to clock adjustment; on some platforms, setting the clock backward can reset the rate limiter.

**Remediation:**
- Add a **global** (cross-device) rate limiter with a hard upper bound
- Use a monotonic timer (`Stopwatch` or `DateTime.now().microsecondsSinceEpoch` with monotonic checks) instead of wall clock
- Bind rate limiting to authenticated peer IDs post-handshake, not to BLE device IDs

---

### HIGH-2: Peripheral Client Set Is Never Cleaned Up — Unbounded Memory Growth

**File:** `ble_transport.dart`, lines 68–69, 222–228  

```dart
final Set<String> _peripheralClients = {};

// In the write callback:
_peripheralClients.add(deviceId);
if (_peripheralClients.length > config.maxConnections) {
  _log('Peripheral connection limit reached — ignoring write from $deviceId');
  return null;
}
```

**The Bug:** `_peripheralClients` only grows (via `add`). It is never cleaned up when peripheral clients disconnect. After enough disconnection/reconnection cycles, _peripheralClients.length will permanently exceed `maxConnections`, and **all future peripheral writes will be rejected** — a permanent denial of service.

Additionally, there's no callback for peripheral client disconnection to remove stale entries.

**Remediation:**
- Listen for BLE peripheral disconnection events and remove the device from `_peripheralClients`
- Add periodic cleanup (e.g., in idle timer) to remove stale entries
- At minimum, use a bounded LRU set similar to the Noise session manager

---

### HIGH-3: Missing Nonce Overflow Protection in Transport CipherState

**File:** `noise_protocol.dart`, line 90  

```dart
if (_nonce > 0xFFFFFFFF) throw const NoiseException(NoiseError.nonceExceeded);
```

This checks if `_nonce` exceeds 32-bit range. However:

1. The nonce is incremented **unconditionally** on decrypt (line 160), even when `useExtractedNonce` is true. This means the **internal counter** climbs independently of actual received nonces, and can overflow before the `shouldRekey` threshold (1,000,000) on the `NoiseSession` layer.
2. The check uses `>` but should use `>=` — when `_nonce == 0xFFFFFFFF`, one more encrypt will set it to `0x100000000` which exceeds the check, but that specific call already used `0xFFFFFFFF` as the nonce without error.

**Remediation:**
- Change to `>= 0xFFFFFFFF` for strict bounds
- Don't increment `_nonce` during `decrypt` when `useExtractedNonce` is true
- The rekey threshold (1M) should fire well before 4B, but the defense-in-depth check should be exact

---

### HIGH-4: Replay Window Bit-Shift Math Has Off-by-One Bug

**File:** `noise_protocol.dart`, lines 181–206

```dart
void _markNonceAsSeen(int receivedNonce) {
  if (receivedNonce > _highestReceivedNonce) {
    final shift = receivedNonce - _highestReceivedNonce;
    if (shift >= replayWindowSize) {
      _replayWindow.fillRange(0, replayWindowBytes, 0);
    } else {
      // Shift window right
      for (var i = replayWindowBytes - 1; i >= 0; i--) {
        final sourceIdx = i - shift ~/ 8;   // ← integer division issue
        int newByte = 0;
        if (sourceIdx >= 0) {
          newByte = _replayWindow[sourceIdx] >> (shift % 8);
          if (sourceIdx > 0 && shift % 8 != 0) {
            newByte |= _replayWindow[sourceIdx - 1] << (8 - shift % 8);
          }
        }
        _replayWindow[i] = newByte & 0xFF;
      }
    }
```

**The Bug:** The bitwise window shift logic has a subtle error when `shift` is not byte-aligned. The computation `sourceIdx = i - shift ~/ 8` computes the source byte, but the bit-level shift `>> (shift % 8)` can lose bits at the boundary between bytes. Specifically, when `shift % 8 != 0` and `sourceIdx` is exactly 0, the `sourceIdx - 1` guard prevents reading below index 0 but silently drops bits that should carry over from a conceptual negative index. This can cause **previously-seen nonces to be forgotten**, allowing replay attacks on nonces near the window boundary.

**Remediation:**
- Replace the manual bit-shift with a well-tested sliding window implementation
- Add comprehensive unit tests with nonces spanning byte boundaries
- Consider using a simpler rolling bitmap library

---

### HIGH-5: Emergency Rebroadcast Creates Duplicate Packets with Same ID

**File:** `mesh_emergency_repository.dart`, lines 104–110

```dart
// Broadcast multiple times for reliability
for (var i = 0; i < _config.emergencyRebroadcastCount; i++) {
  await _transport.broadcastPacket(packet);
  if (i < _config.emergencyRebroadcastCount - 1) {
    await Future.delayed(const Duration(milliseconds: 500));
  }
}
```

**The Bug:** The same `packet` object (same `packetId`) is broadcast 3 times. However, receiving peers' deduplicators will mark the packet as a duplicate after the first receipt — meaning the 2nd and 3rd broadcasts are **wasted**. Worse, if the first broadcast is lost and a second arrives, it works — but the intended reliability gain is only 1 retry, not 2.

The real problem: for an attacker observing the BLE transmissions, seeing 3 identical broadcasts at 500ms intervals is a strong traffic analysis signal that an emergency was just triggered.

**Remediation:**
- Generate a new `packetId` (different timestamp) for each rebroadcast
- Or: use a rebroadcast counter in the flags field so deduplicators can distinguish retries
- Add small random jitter to the 500ms interval to reduce traffic analysis fingerprinting

---

### HIGH-6: Topology Announce Not Signed at Source — Mesh Poisoning

**File:** `mesh_service.dart`, lines 345–357

```dart
Future<void> _sendAnnounce(MessageType type) async {
  final neighborIds = _currentPeers.map((p) => p.peerId).toList();
  final payload = BinaryProtocol.encodeDiscoveryPayload(
    neighbors: neighborIds,
  );
  final packet = BinaryProtocol.buildPacket(
    type: type,
    sourceId: _myPeerId,
    payload: payload,
    ttl: FluxonPacket.maxTTL,
  );
  await _rawTransport.broadcastPacket(packet);  // signed by broadcastPacket
}
```

While the packet is signed before broadcast (via `MeshService.broadcastPacket`), when this packet is **relayed** by intermediate nodes, the relay logic (line 289) calls `_rawTransport.broadcastPacket(relayed)` which sends it **without re-signing**. The original signature from the source is preserved — but the intermediate relayer doesn't validate the topology claims.

**Exploit:** An attacker injects a topology announce packet claiming a high-value target node has the attacker as its only neighbor. This causes all mesh routing to route traffic through the attacker (Sybil/Eclipse attack). The two-way edge verification in `TopologyTracker` partially mitigates this, but only if the target node has recently sent its own announce.

**Remediation:**
- Topology announce packets should only be trusted from directly-connected, Noise-authenticated peers
- When relaying topology announces, verify that the `sourceId` matches a known authenticated peer
- Limit TTL on topology packets more aggressively

---

### HIGH-7: `_connectingDevices` Set Not Cleared on All Failure Paths

**File:** `ble_transport.dart`, lines 411, 500–502

```dart
_connectingDevices.add(deviceId);
// ...
} catch (e) {
  _log('ERROR connecting to $deviceId: $e');
  _connectingDevices.remove(deviceId);  // Only removed on catch
}
```

**The Bug:** If the `connect()` call succeeds but service discovery or characteristic lookup fails, the `_connectingDevices.remove(deviceId)` calls on lines 432, 448, 459 are correct. However, if `char.setNotifyValue(true)` (line 465) throws, the exception is caught at line 499, and `_connectingDevices.remove(deviceId)` runs — but `_connectedDevices[deviceId]` was never set because the exception occurred before line 471.

The device is now in a limbo state: removed from `_connectingDevices`, never added to `_connectedDevices`, but the characteristic subscription and connection state listener may have partially set up, leaking resources.

Additionally, if `result.device.connectionState.listen` (line 480) throws, `_connectingDevices` is removed but the device is already in `_connectedDevices`. The disconnection listener was never registered, so the device will never be cleaned up on disconnect.

**Remediation:**
- Use a try/finally pattern that ensures cleanup in all cases
- Move `_connectingDevices.remove(deviceId)` to a `finally` block
- Track partial setup state and clean up on any failure

---

## MEDIUM Findings

### MED-1: Packet ID Collision — Weak Uniqueness

**File:** `packet.dart`, lines 52–54

```dart
String _computePacketId() {
  return '${HexUtils.encode(sourceId)}:$timestamp:${type.value}';
}
```

The packet ID is `sourceId:timestamp:type`. If two packets of the same type from the same source arrive within the same millisecond, they get the **same packet ID**. The deduplicator will silently drop the second packet.

**Impact:** Under high message rates (e.g., emergency alerts with rebroadcast, rapid location updates), legitimate packets can be dropped as duplicates.

**Remediation:** Include a random nonce or incrementing sequence number in the packet ID computation.

---

### MED-2: GATT Characteristic Properties Overly Permissive

**File:** `ble_transport.dart`, lines 244–253

```dart
properties: [
  ble_p.CharacteristicProperties.write.index,
  ble_p.CharacteristicProperties.writeWithoutResponse.index,
  ble_p.CharacteristicProperties.notify.index,
  ble_p.CharacteristicProperties.read.index,    // ← unnecessary
],
permissions: [
  ble_p.AttributePermissions.readable.index,
  ble_p.AttributePermissions.writeable.index,
],
```

The `read` property and `readable` permission allow any connected central to **read** the characteristic value at any time. This could expose the last broadcast packet to passive observers who simply read the characteristic without subscribing.

**Remediation:** Remove `read` and `readable` since the protocol only needs `write`/`writeWithoutResponse` for inbound and `notify` for outbound.

---

### MED-3: Handshake Rate Limiter Window Is Per Device ID, Not Per Session

**File:** `noise_session_manager.dart`, lines 109–114

```dart
if (now - peer.lastHandshakeTime < 60000) {
  peer.handshakeAttempts++;
  if (peer.handshakeAttempts > 5) return (...null...);
} else {
  peer.handshakeAttempts = 1;
}
```

The rate limiter allows 5 handshake attempts per 60-second window per device ID. Since Android BLE uses random/resolvable MAC addresses, an attacker can rotate their address and get unlimited handshakes, each consuming CPU for Noise XX DH operations.

**Remediation:**
- Add a global handshake rate limit (e.g., max 20 handshakes/minute across all devices)
- Track handshake attempts per IP/address range on platforms where possible
- Consider adding a proof-of-work puzzle to the first handshake message

---

### MED-4: Group Key Never Rotated — Compromised Key Has Unlimited Lifetime

**File:** `group_manager.dart`, `group_cipher.dart`

Once a group key is derived from `passphrase + salt`, it is used for the **entire lifetime** of the group. There is a `groupKeyRotation` message type defined (`0x0D`) but it is **never implemented** — no key rotation logic exists anywhere in the codebase.

**Impact:** If a group member's device is compromised or the passphrase leaks, the attacker can decrypt all past and future group traffic indefinitely.

**Remediation:**
- Implement key rotation using the existing `groupKeyRotation` message type
- Rotate keys periodically (e.g., every 24 hours) and on member removal
- Use a forward-ratchet so compromising the current key doesn't expose past messages

---

### MED-5: `broadcastPacket` Sends Plaintext via Peripheral When No Central Connections Exist

**File:** `ble_transport.dart`, lines 551–592

When a device has no central connections (only peripheral role active), `broadcastPacket` still sends via `BlePeripheral.updateCharacteristic` in plaintext. This means **all broadcasts are unencrypted** until at least one central connection with Noise session is established.

**Remediation:** Do not update the peripheral characteristic unless at least one authenticated client is connected.

---

### MED-6: `decodeChatPayload` Uses `allowMalformed: true` — Accepts Invalid UTF-8

**File:** `binary_protocol.dart`, line 39

```dart
final raw = utf8.decode(payload, allowMalformed: true);
```

Malformed UTF-8 is silently accepted and converted to replacement characters (U+FFFD). While this prevents crashes, it can be used for:
- **Encoding confusion attacks**: display different text on different platforms
- **Homoglyph attacks**: mix valid characters with replacement markers
- **Log injection**: if the decoded text appears in logs

**Remediation:** Reject malformed UTF-8 or sanitize the result before displaying.

---

### MED-7: No Connection Timeout for Peripheral Clients

**File:** `ble_transport.dart`

The peripheral role has no mechanism to:
1. Detect when a connected central has become unresponsive
2. Forcefully disconnect stale peripheral clients
3. Timeout connections that haven't completed a Noise handshake within N seconds

An attacker can connect and hold the connection open indefinitely without completing a handshake, consuming one of the limited connection slots.

**Remediation:**
- Add a handshake timeout (e.g., 30 seconds) that disconnects peers who haven't completed authentication
- Implement a keepalive/ping mechanism for peripheral clients

---

### MED-8: Gossip Sync Does Not Authenticate Sync Requests

**File:** `gossip_sync.dart`, lines 68–83

```dart
Future<void> handleSyncRequest({
  required Uint8List fromPeerId,
  required Set<String> peerHasIds,
}) async {
```

The `handleSyncRequest` method accepts any peer ID and set of packet IDs. There's no verification that:
1. `fromPeerId` is actually connected and authenticated
2. The sync request itself came from who it claims to be
3. The packet IDs in `peerHasIds` are valid/reasonable

An attacker can send a sync request claiming to have zero packets, causing the victim to re-transmit all stored packets — a bandwidth amplification attack.

**Remediation:**
- Only process sync requests from Noise-authenticated peers
- Rate-limit sync responses per peer
- Limit the number of packets resent per sync round

---

## LOW / INFORMATIONAL Findings

### LOW-1: Device Terminal Repository Has No Authentication

**File:** `ble_device_terminal_repository.dart`

The `BleDeviceTerminalRepository` connects to hardware devices and sends/receives raw bytes with no authentication, encryption, or integrity checking. Any device advertising the Fluxon hardware service UUID can impersonate real hardware.

**Note:** The code comments indicate this is a placeholder. Ensure authentication is added before production use.

---

### LOW-2: `_cachedSigningKeyBytes` Stores Signing Key in Dart Heap

**File:** `signatures.dart`, lines 13–14

```dart
static SecureKey? _cachedSigningKey;
static Uint8List? _cachedSigningKeyBytes;   // ← plaintext in heap
```

While `_cachedSigningKey` is in a libsodium secure buffer, `_cachedSigningKeyBytes` is a **regular Dart `Uint8List`** — it sits in GC-managed heap memory and can be found via memory dumps.

**Remediation:** Avoid caching the raw bytes; use a hash for key-identity comparison instead.

---

### LOW-3: Ephemeral Key Extracted to Dart Heap Before Zeroing

**File:** `noise_protocol.dart`, lines 490–496

```dart
void _generateEphemeralKey() {
  final sodium = sodiumInstance;
  final keyPair = sodium.crypto.box.keyPair();
  localEphemeralPrivate = keyPair.secretKey.extractBytes();  // ← extractBytes copies to Dart heap
  localEphemeralPublic = Uint8List.fromList(keyPair.publicKey);
  keyPair.secretKey.dispose(); // Zero SecureKey after extracting bytes
}
```

`extractBytes()` copies the secret key from libsodium's mlock'd memory into a regular `Uint8List`. The original `SecureKey` is disposed, but the copy lives in Dart's GC heap — potentially surviving until a GC cycle and being visible in memory dumps.

**Remediation:** Keep ephemeral keys as `SecureKey` objects and use the `SecureKey`-based crypto APIs rather than extracting bytes.

---

### LOW-4: Scan Filter Matches by Name Substring "fluxon"

**File:** `ble_transport.dart`, lines 314–316

```dart
final hasName =
    result.device.platformName.toLowerCase().contains('fluxon') ||
    (result.advertisementData.advName.toLowerCase().contains('fluxon'));
```

While the comment at line 309 correctly notes this is only a "discovery hint," an attacker can set their device name to "fluxon" to trigger connection attempts. Combined with the provisioning window (CRIT-3), this lowers the barrier for malicious connections.

---

### LOW-5: Topology Tracker `_sanitize` Pads Short IDs with Zeros

**File:** `topology_tracker.dart`, lines 187–191

```dart
} else if (data.length < routingIdSize) {
  normalized = Uint8List(routingIdSize);
  normalized.setAll(0, data);
}
```

If a malformed peer ID shorter than 32 bytes is received, it's zero-padded to 32 bytes. This means different short inputs that share a prefix could collide to the same routing ID.

---

### LOW-6: Deduplicator Claims "Thread-safe" but Dart Is Single-Threaded

**File:** `deduplicator.dart`, line 1

```dart
/// Thread-safe deduplicator with LRU eviction and time-based expiry.
```

This is a documentation inaccuracy. Dart is single-threaded (isolate-based). The class is **not** safe for cross-isolate use. If ever used with Dart isolates, a shared-memory race condition would exist.

---

### LOW-7: No Input Validation on `emergencyPayload.message` Length

**File:** `binary_protocol.dart`, lines 98–113

The emergency payload encodes `message.length` as a `Uint16` (max 65535 bytes), but the max payload size for the entire packet is 512 bytes. A crafted emergency payload with a malicious `msgLen` of 65535 would be rejected by the packet-level `maxPayloadSize` check, but the mismatch in acceptable ranges could cause confusion.

---

### LOW-8: `FluxonPacket.decode` Creates Sub-list Views, Not Copies

**File:** `packet.dart`, lines 136–156

```dart
final sourceId = Uint8List.sublistView(data, offset, offset + 32);
final destId = Uint8List.sublistView(data, offset, offset + 32);
final payload = Uint8List.sublistView(data, offset, offset + payloadLen);
```

These are **views** into the original `data` buffer, not copies. If the caller's buffer is reused or modified after decoding, the packet's fields will be silently corrupted. This is a correctness issue rather than a security issue, but it could lead to unpredictable behavior in relay scenarios.

---

### LOW-9: Log Messages Leak Device IDs

**File:** `ble_transport.dart` (throughout)

Multiple log statements include the raw BLE device ID string:

```dart
_log('Received write from $deviceId, char=$characteristicId, len=${value?.length}');
_log('Attempting to connect to $deviceId...');
_log('SUCCESS: Connected to $deviceId');
```

While `SecureLogger` claims to "never log PII," BLE device IDs (MAC addresses on some platforms) can be used to identify and track specific devices.

**Remediation:** Hash or truncate device IDs before logging.

---

## Attack Surface Summary

| Attack Vector | Severity | Status |
|--------------|----------|--------|
| Passive BLE sniffing of peripheral broadcasts | Critical | Unmitigated (CRIT-1) |
| Source ID spoofing after auth | Critical | Unmitigated (CRIT-2) |
| Unsigned packet injection during handshake window | Critical | Unmitigated (CRIT-3) |
| BLE MAC rotation to bypass rate limits | High | Partially mitigated |
| Peripheral connection slot exhaustion | High | Unmitigated (HIGH-2) |
| Topology poisoning via relay | High | Partially mitigated by two-way verification |
| Emergency alert spoofing | High | Unmitigated (via CRIT-3) |
| Group key compromise (no rotation) | Medium | Unmitigated (MED-4) |
| Gossip sync amplification | Medium | Unmitigated (MED-8) |
| Memory-resident key material | Low | Partially mitigated |

---

## Prioritized Remediation Roadmap

### Phase 1 — Immediate (Security-Critical)
1. **Fix CRIT-1**: Do not send unencrypted data via peripheral characteristic to unauthenticated clients
2. **Fix CRIT-2**: Bind authenticated peer ID to sourceId validation in `_handleIncomingData`
3. **Fix CRIT-3**: Reject non-handshake packets from devices without established Noise sessions
4. **Fix HIGH-2**: Clean up `_peripheralClients` set on disconnection

### Phase 2 — Short-Term (1-2 Sprints)
5. **Fix CRIT-4**: Add handshake state cleanup on all failure paths
6. **Fix HIGH-1**: Add global rate limiting + monotonic timer
7. **Fix HIGH-3**: Fix nonce overflow edge case
8. **Fix HIGH-4**: Audit and unit-test replay window bit-shift logic
9. **Fix MED-7**: Add connection timeout for unauthenticated peripheral clients
10. **Fix MED-3**: Add global handshake rate limit

### Phase 3 — Medium-Term
11. **Fix HIGH-5**: Use distinct packet IDs for emergency rebroadcasts
12. **Fix HIGH-6**: Restrict topology announce trust to direct peers only
13. **Fix MED-1**: Add random nonce to packet ID computation
14. **Fix MED-2**: Remove unnecessary `read` property from GATT characteristic
15. **Fix MED-4**: Implement group key rotation
16. **Fix MED-8**: Authenticate and rate-limit gossip sync

### Phase 4 — Hardening
17. Fix remaining LOW findings
18. Add fuzz testing for packet decode, payload decode, and handshake message processing
19. Add integration tests for the full handshake → encrypted session lifecycle
20. Add BLE traffic analysis resistance (padding, timing jitter for GATT notifications)

---

## Methodology Notes

This audit was performed via static analysis of the complete source code. The following threat models were considered:

- **Passive BLE eavesdropper** (within radio range, sniffing advertisements and GATT traffic)
- **Active BLE attacker** (connecting as central or peripheral, injecting/manipulating packets)
- **Compromised mesh peer** (authenticated but malicious node in the mesh)
- **Resource exhaustion** (DoS attacks targeting connection slots, CPU, memory)
- **Cryptographic weaknesses** (key management, nonce handling, replay protection)
- **Traffic analysis** (metadata leakage, timing patterns, packet sizes)

All findings reference specific file names and line numbers. No automated exploit code was generated.
