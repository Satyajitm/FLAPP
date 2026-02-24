# FluxonApp — Security Audit Report

**Date:** 2026-02-24  
**Auditor:** Senior Security Skill (Automated + Manual Review)  
**Scope:** Full repository — `lib/`, Android manifest, iOS config, dependencies  
**Methodology:** Three automated scripts + line-by-line manual review of all P0–P3 security-critical paths

---

## Executive Summary

FluxonApp is a Flutter-based BLE mesh networking app with libsodium cryptography, Noise XX handshake protocol, and Ed25519 packet signing. The overall security architecture is **well-designed** — the crypto primitives are correctly chosen, secure storage is properly used via `flutter_secure_storage`, and the Noise XX handshake implementation follows the spec closely.

However, the audit found **73 total findings** across three automated tools and manual review:

| Severity | Automated | Manual | Total |
|----------|-----------|--------|-------|
| 🔴 CRITICAL | 3 | 4 | **7** |
| 🟠 HIGH | 7 + 11 + 9 = 27 | 5 | **32** |
| 🟡 MEDIUM | 12 + 6 + 15 = 33 | 1 | **34** |
| 🟢 LOW | 0 + 2 + 2 = 4 | 0 | **4** |

---

## 🔴 CRITICAL Findings

### C1 — Insecure RNG in RelayController (`dart:math Random()`)

**File:** `lib/core/mesh/relay_controller.dart:22`  
**Code:**
```dart
static final _rng = Random();
```

**Impact:** `dart:math Random()` uses a non-cryptographic PRNG seeded from a predictable source. While this is used only for relay jitter timing, an attacker who can predict the jitter can:
- Identify which node is the originator vs relay (traffic analysis)
- Time relay windows for targeted DoS

**Recommendation:**  
Replace with a cryptographically secure random source:
```dart
import 'dart:math';
static final _rng = Random.secure();
```

**Severity Justification:** The jitter values are small (5–220ms), so practical exploitability is moderate, but using `Random()` anywhere in a security-critical app sets a dangerous precedent and violates the project's own crypto hygiene rules.

---

### C2 — Broadcast Packets Skip Noise Encryption

**File:** `lib/core/transport/ble_transport.dart:523–553`  
**Code:**
```dart
Future<void> broadcastPacket(FluxonPacket packet) async {
  final data = packet.encodeWithSignature();
  // ...
  for (final entry in _peerCharacteristics.entries) {
    await entry.value.write(data, withoutResponse: true);
  }
}
```

**Impact:** Unlike `sendPacket()` (which encrypts via Noise session on line 506), `broadcastPacket()` sends the **raw encoded packet** to all peers without per-link Noise encryption. This means:
- Packet headers (source ID, type, timestamp) are visible to any BLE observer
- Even though the payload may be group-encrypted, metadata analysis reveals traffic patterns
- A passive BLE sniffer can fingerprint users and map social graphs

**Recommendation:**  
For each connected peer with an established Noise session, encrypt the broadcast data through that peer's session before writing:
```dart
for (final entry in _peerCharacteristics.entries) {
  var sendData = data;
  if (_noiseSessionManager.hasSession(entry.key)) {
    final encrypted = _noiseSessionManager.encrypt(data, entry.key);
    if (encrypted != null) sendData = encrypted;
  }
  await entry.value.write(sendData, withoutResponse: true);
}
```

---

### C3 — No Signature Verification on Incoming Packets

**File:** `lib/core/transport/ble_transport.dart:584–606`  
**Code:**
```dart
var packet = FluxonPacket.decode(packetData, hasSignature: true);
packet ??= FluxonPacket.decode(packetData, hasSignature: false);
if (packet == null) {
  _log('Failed to decode packet from $fromDeviceId');
  return;
}
// ... packet is used directly without signature verification
```

**Impact:** Packets are decoded but **Ed25519 signatures are never verified** before processing. An attacker can:
- Forge packets with arbitrary source IDs
- Inject fake topology announcements to corrupt routing
- Send fake emergency alerts attributed to other peers
- Bypass the entire Ed25519 signing scheme

**Recommendation:**  
After decoding, verify the signature using `Signatures.verify()` and the peer's signing public key obtained from the Noise handshake:
```dart
if (packet.signature != null) {
  final peerSigningKey = _noiseSessionManager.getSigningPublicKey(fromDeviceId);
  if (peerSigningKey != null) {
    final encoded = packet.encode(); // Get unsigned data
    if (!Signatures.verify(encoded, packet.signature!, peerSigningKey)) {
      _log('Signature verification FAILED — dropping packet');
      return;
    }
  }
}
```

---

### C4 — Unsigned Packets Accepted Without Warning

**File:** `lib/core/transport/ble_transport.dart:586`  
**Code:**
```dart
packet ??= FluxonPacket.decode(packetData, hasSignature: false);
```

**Impact:** If a packet fails to decode with a signature, the code silently falls back to accepting it **without** a signature. This completely undermines the packet authentication system — an attacker can simply omit the signature and the packet will be accepted.

**Recommendation:**  
After the Noise handshake is complete for a given peer, **reject unsigned packets** from that peer. Only allow unsigned packets from devices that haven't completed a handshake yet (for backward compatibility during the handshake phase):
```dart
if (packet.signature == null && _noiseSessionManager.hasSession(fromDeviceId)) {
  _log('Unsigned packet from authenticated peer — rejecting');
  return;
}
```

---

### C5 — Message Storage Writes Plaintext to Disk

**File:** `lib/core/services/message_storage_service.dart`  
**Code:**
```dart
await file.writeAsString(jsonEncode(jsonList), flush: true);
```

**Impact:** Chat messages are persisted as **unencrypted plaintext JSON** to the app's documents directory. On a rooted/jailbroken device, or via backup extraction, all message history is readable. This includes:
- Message content (chat text)
- Sender display names
- Timestamps
- Peer IDs (in message metadata)

**Recommendation:**  
Encrypt the JSON string before writing to disk using the group key or a dedicated file-encryption key stored in `flutter_secure_storage`:
```dart
final encrypted = groupCipher.encrypt(
  Uint8List.fromList(utf8.encode(jsonEncode(jsonList))),
  fileEncryptionKey,
);
await file.writeAsBytes(encrypted!, flush: true);
```

---

### C6 — NoiseSession re-keying `shouldRekey` flag is checked but never acted on

**File:** `lib/core/crypto/noise_session.dart:58–59`  
**Code:**
```dart
bool get shouldRekey =>
    _messagesSent >= rekeyThreshold || _messagesReceived >= rekeyThreshold;
```

**Impact:** The session tracks message counts and exposes a `shouldRekey` boolean, but **no code in the entire codebase checks or acts on this flag**. After 1,000,000 messages (or never, depending on traffic), the session keys are never rotated. While the counter nonce provides uniqueness within a session, long-lived sessions increase the window for key compromise propagation.

**Recommendation:**  
Implement re-key checking in `NoiseSessionManager.encrypt()` / `decrypt()`:
```dart
if (session.shouldRekey) {
  SecureLogger.warning('Noise session for $deviceId needs re-key');
  // Tear down session and re-initiate handshake
}
```

---

### C7 — Nonce overflow check uses wrong upper bound

**File:** `lib/core/crypto/noise_protocol.dart:90`  
**Code:**
```dart
if (_nonce > 0xFFFFFFFF) throw const NoiseException(NoiseError.nonceExceeded);
```

**Impact:** The nonce is stored as a 64-bit Dart `int`, but the nonce buffer is built as an 8-byte big-endian value at line 95. For the original ChaCha20-Poly1305 (not IETF), the nonce is 8 bytes, so the upper bound of `0xFFFFFFFF` (32-bit) is artificially low. However, the `useExtractedNonce` mode prepends only a **4-byte** nonce (line 109), so the 32-bit limit is correct for that path. For the non-extracted path (Noise handshake), the 32-bit limit is overly conservative but safe.

**Status:** Not exploitable but worth noting for correctness. The asymmetry between the 4-byte extracted nonce and the 8-byte nonce buffer is a potential confusion point for future maintainers.

---

## 🟠 HIGH Findings

### H1 — BLE Advertising Leaks Device Name

**File:** `lib/core/transport/ble_transport.dart:242`  
**Code:**
```dart
await ble_p.BlePeripheral.startAdvertising(
  services: [serviceUuidStr],
  localName: 'Fluxon',
);
```

**Impact:** The `localName: 'Fluxon'` is broadcast in the clear to all BLE observers within range (~100m). This:
- Fingerprints the device as a Fluxon user
- Enables passive tracking of Fluxon users across locations
- Combined with BLE MAC address, allows building a movement profile

**Recommendation:**  
Remove the `localName` parameter and rely solely on the service UUID for discovery:
```dart
await ble_p.BlePeripheral.startAdvertising(
  services: [serviceUuidStr],
);
```

---

### H2 — Missing `android:networkSecurityConfig` 

**File:** `android/app/src/main/AndroidManifest.xml`  

**Impact:** No `android:networkSecurityConfig` is specified in the `<application>` tag. This means:
- On Android 9+ the app defaults to blocking cleartext, but on older versions it doesn't
- No certificate pinning for OpenStreetMap tile fetching (`INTERNET` permission is granted)
- A MITM attacker on the network could serve malicious map tiles or inject JavaScript via WebView tiles

**Recommendation:**  
Add a Network Security Config:
```xml
<application
    android:networkSecurityConfig="@xml/network_security_config"
    ...>
```
Create `android/app/src/main/res/xml/network_security_config.xml`:
```xml
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system"/>
        </trust-anchors>
    </base-config>
</network-security-config>
```

---

### H3 — No Rate-Limiting on BLE Packet Processing

**File:** `lib/core/transport/ble_transport.dart:441–443`  
**Code:**
```dart
char.onValueReceived.listen((data) {
  _handleIncomingData(Uint8List.fromList(data), fromDeviceId: deviceId);
});
```

**Impact:** Incoming BLE notifications are processed without any rate limiting. A malicious peer could flood the device with rapid BLE notifications, causing:
- CPU exhaustion from repeated packet decoding/signature verification
- Memory pressure from deduplicator growth
- Battery drain from sustained processing

**Recommendation:**  
Add per-device rate limiting:
```dart
final _lastPacketTime = <String, DateTime>{};
static const _minPacketIntervalMs = 50; // 20 packets/sec max

// In _handleIncomingData:
final lastTime = _lastPacketTime[fromDeviceId];
if (lastTime != null &&
    DateTime.now().difference(lastTime).inMilliseconds < _minPacketIntervalMs) {
  return; // Rate limited
}
_lastPacketTime[fromDeviceId] = DateTime.now();
```

---

### H4 — Decompression Bomb Risk in `Compression.decompress()`

**File:** `lib/shared/compression.dart:13–19`  
**Code:**
```dart
static Uint8List? decompress(Uint8List data) {
  try {
    final codec = ZLibCodec();
    return Uint8List.fromList(codec.decode(data));
  } catch (_) {
    return null;
  }
}
```

**Impact:** A malicious peer could send a small compressed payload that decompresses to an extremely large buffer (zip bomb), causing OOM and app crash.

**Recommendation:**  
Add output size limits:
```dart
static Uint8List? decompress(Uint8List data, {int maxOutputSize = 65536}) {
  try {
    final codec = ZLibCodec();
    final decoded = codec.decode(data);
    if (decoded.length > maxOutputSize) return null; // Zip bomb protection
    return Uint8List.fromList(decoded);
  } catch (_) {
    return null;
  }
}
```

---

### H5 — Ephemeral Private Key Bytes Not Zeroized After Extraction

**File:** `lib/core/crypto/noise_protocol.dart:490–496`  
**Code:**
```dart
void _generateEphemeralKey() {
  final sodium = sodiumInstance;
  final keyPair = sodium.crypto.box.keyPair();
  localEphemeralPrivate = keyPair.secretKey.extractBytes();
  localEphemeralPublic = Uint8List.fromList(keyPair.publicKey);
  keyPair.secretKey.dispose(); // Zero SecureKey after extracting bytes
}
```

**Impact:** While `keyPair.secretKey.dispose()` zeroes the `SecureKey`, the extracted bytes at `localEphemeralPrivate` are a regular `Uint8List` that remains in heap memory. The `dispose()` method on `NoiseHandshakeState` does zero these (lines 514–533), but there's a window between extraction and disposal where the secret key bytes live in unprotected heap memory. In Dart's garbage-collected environment, this is difficult to fully mitigate, but the risk should be documented.

**Status:** Partially mitigated by the `dispose()` method. Accept risk with documentation.

---

### H6 — `writeWithoutResponse` Used for All Packet Sends

**Files:** `lib/core/transport/ble_transport.dart:513, 536, 634, 684`  

**Impact:** All BLE packet writes use `withoutResponse: true`, which means:
- No acknowledgment that the peer received the data
- Silent data loss if the BLE link quality is poor
- No flow control — fast sender can overwhelm slow receiver's buffer

**Recommendation:**  
Use `withoutResponse: false` for critical packet types (handshake messages, emergency alerts). Keep `withoutResponse: true` for high-frequency broadcasts (location updates, chat) where latency matters more than reliability:
```dart
final isReliable = packet.type == MessageType.handshake ||
                   packet.type == MessageType.emergencyAlert;
await char.write(encodedData, withoutResponse: !isReliable);
```

---

### H7 — No Input Validation on BLE Data Length at Transport Layer

**File:** `lib/core/transport/ble_transport.dart:559–606`  

**Impact:** The `_handleIncomingData` method processes incoming BLE data without checking minimum/maximum length bounds before attempting Noise decryption and packet decoding. While `FluxonPacket.decode()` has its own length checks, passing excessively large data to `_noiseSessionManager.decrypt()` could trigger internal buffer allocations.

**Recommendation:**
```dart
// At the top of _handleIncomingData:
if (data.isEmpty || data.length > 4096) {
  _log('Invalid data length ${data.length} — dropping');
  return;
}
```

---

## 🟡 MEDIUM Findings

### M1 — `sublist()` Without Length Checks (Multiple Locations)

**Files:**
- `lib/core/protocol/binary_protocol.dart:124, 159, 187`
- `lib/features/group/join_group_screen.dart:140`
- `lib/core/mesh/topology_tracker.dart:134`

**Impact:** Several `sublist()` calls do not validate that the source buffer is long enough, which can throw `RangeError` and crash the app. Most are in parsing paths that handle external (potentially malicious) data.

**Recommendation:** Add length checks before every `sublist()` call on externally-sourced data.

---

### M2 — Unguarded Decode Operations (Multiple Locations)

**Files:**
- `lib/core/identity/peer_id.dart:14` — `PeerId.fromHex()` doesn't catch `FormatException`
- `lib/core/mesh/topology_tracker.dart:135` — `HexUtils.decode()` unguarded
- `lib/core/transport/ble_transport.dart:585–586` — `FluxonPacket.decode()` unguarded

**Impact:** Malformed data from a peer could trigger unhandled exceptions, crashing the app (denial of service).

**Recommendation:** Wrap all decode operations on external data in `try/catch` with appropriate error logging.

---

### M3 — Trusted Peers Not Persisted Across App Restarts

**File:** `lib/core/identity/identity_manager.dart:18`  
**Code:**
```dart
final Set<PeerId> _trustedPeers = {};
```

**Impact:** The trusted peer set is in-memory only. After an app restart, all peers must re-handshake. This isn't a security vulnerability per se, but it prevents implementing trust-on-first-use (TOFU) or peer blocklists that survive across sessions.

**Recommendation:** Persist the trusted peer set to `flutter_secure_storage` and load on initialization.

---

### M4 — No Maximum Connection Limit Enforcement on Peripheral Role

**File:** `lib/core/transport/ble_transport.dart`

**Impact:** The central role enforces `config.maxConnections` (line 385), but the peripheral role (GATT server) has no limit on how many remote centrals can connect. An attacker could open many connections to exhaust BLE resources.

**Recommendation:** Track peripheral-side connections and reject new ones when at capacity.

---

### M5 — `ACCESS_FINE_LOCATION` Permission Requested When Coarse May Suffice

**File:** `android/app/src/main/AndroidManifest.xml:10`

**Impact:** `ACCESS_FINE_LOCATION` grants GPS precision (~3m) when BLE scanning only requires `ACCESS_COARSE_LOCATION`. The fine location is needed for the map/GPS feature, so this is justified, but should be documented and the map feature should be the only code path that actually uses fine location.

**Status:** Acceptable — but consider requesting fine location only when the map feature is active, not at startup.

---

## 🟢 LOW Findings

### L1 — MTU Negotiation Falls Back to 23 Bytes Silently

**File:** `lib/core/transport/ble_transport.dart:408`

**Impact:** If MTU negotiation fails, the fallback is 23 bytes — far too small for any Fluxon packet (minimum 78 bytes header + 64 bytes signature = 142 bytes). Packets will be silently truncated by the BLE stack. The 256-byte warning on line 404 helps, but the 23-byte fallback should be treated as a hard error.

---

### L2 — False-Positive Scanner Flags

The security auditor flagged two items that are **not actual vulnerabilities**:

1. **`user_profile_manager.dart:5` — "hardcoded secret"**: `_nameKey = 'user_display_name'` is a storage key constant, not a cryptographic secret. **False positive.**

2. **`topology_tracker.dart:87` — "hardcoded secret"**: `cacheKey = '$source:$target:$maxHops'` is a cache key string, not crypto material. **False positive.**

3. **`noise_protocol.dart` zero-nonce warnings**: The flagged `Uint8List(0)` and `Uint8List(8)` are used correctly per the Noise Protocol spec (HKDF empty input, reusable nonce buffer). **False positives.**

---

## STRIDE Threat Model Summary

The threat modeler identified **32 threats** across 6 STRIDE categories. Key highlights beyond what's covered above:

| Threat | Impact | Current Mitigation | Gap |
|--------|--------|-------------------|-----|
| Stolen Ed25519 private key | Peer impersonation | `flutter_secure_storage` (Android Keystore / iOS Keychain backed) | ✅ Adequate |
| Group key brute-force via weak Argon2id | All group traffic decrypted | Uses `opsLimitModerate` + `memLimitModerate` | ✅ Adequate |
| BLE MAC cloning | Device impersonation | Application-layer identity (Noise XX) | ✅ Adequate |
| Flood attack via unique packets | DoS | Deduplicator with LRU eviction (max 1024) | ⚠️ Rate limiting missing |
| Topology spoofing | Route corruption | Two-way edge verification in BFS | ⚠️ No signature verification on topology packets |
| Key material in logs | Key leak | SecureLogger used throughout, no `print()` calls found | ✅ Adequate |
| Nonce reuse in group cipher | XOR plaintext leak | Random nonces per encryption (`sodium.randombytes.buf()`) | ✅ Adequate |
| Key rotation on member leave | Past traffic compromise | Not implemented | ❌ Missing |

---

## BLE Attack Surface Summary

The BLE analyzer identified **19 findings**. Key highlights:

| Category | Count | Key Issue |
|----------|-------|-----------|
| Advertising | 3 | Device name "Fluxon" broadcast in the clear |
| Transport | 6 | No length validation on incoming BLE data handlers |
| GATT | 6 | Write-without-response on all characteristics |
| Connection | 4 | 10-second timeout (adequate), MTU 512 negotiation |

---

## Dependency Audit

| Package | Version | Security Notes |
|---------|---------|----------------|
| `sodium_libs` | ^2.2.1 | ✅ libsodium sumo — industry-standard crypto |
| `flutter_secure_storage` | ^9.2.4 | ✅ Android Keystore / iOS Keychain backed |
| `flutter_blue_plus` | ^1.35.2 | ⚠️ Check for updates — BLE stack vulnerabilities |
| `ble_peripheral` | ^2.4.0 | ⚠️ Check for updates |
| `crypto` | ^3.0.0 | ✅ Used only for HMAC-SHA256 in Noise HKDF |
| `mobile_scanner` | ^6.0.0 | ⚠️ Camera access — ensure proper permission scoping |
| `path_provider` | ^2.1.5 | ✅ Standard |
| `qr_flutter` | ^4.1.0 | ✅ Display only, no parsing risk |
| `archive` | ^4.0.4 | ⚠️ Not used in lib/ — consider removing if unused |

---

## What's Done Well ✅

1. **Noise XX Protocol Implementation** — Correct message pattern, proper X25519 DH, HKDF-SHA256, and ChaCha20-Poly1305 AEAD. Follows the Noise spec faithfully.

2. **Replay Protection** — Sliding window replay protection with 1024-entry bitmap in `NoiseCipherState`. Well-implemented.

3. **Secure Key Storage** — All key material goes through `flutter_secure_storage`. No `SharedPreferences` for secrets.

4. **No `print()`/`debugPrint()` Calls** — Zero instances found in `lib/`. SecureLogger is used consistently.

5. **Group Cipher** — Random nonces per encryption, Argon2id with moderate parameters, proper AEAD (XChaCha20-Poly1305).

6. **Passphrase Not Persisted** — Group storage correctly stores only the derived key, never the raw passphrase.

7. **Handshake Rate Limiting** — `NoiseSessionManager` limits handshake attempts to 5 per 60 seconds per device.

8. **Peer Cache Size Limits** — `NoiseSessionManager._maxPeers = 500` with LRU eviction prevents unbounded growth.

9. **Packet Timestamp Validation** — ±5 minute window rejects stale/future packets.

10. **Payload Size Cap** — 512-byte max payload enforced at decode time.

11. **Handshake Payload Encryption** — Signing keys are exchanged as AEAD-encrypted payloads within Noise messages 2 and 3, not in the clear.

12. **Sensitive State Zeroization** — `NoiseHandshakeState.dispose()` and `NoiseSymmetricState.split()` zero key material after use.

---

## Prioritized Action Items

| Priority | Finding | File(s) | Effort |
|----------|---------|---------|--------|
| 🔴 P0 | **C3** — Add Ed25519 signature verification on incoming packets | `ble_transport.dart` | Medium |
| 🔴 P0 | **C4** — Reject unsigned packets from authenticated peers | `ble_transport.dart` | Small |
| 🔴 P0 | **C2** — Encrypt broadcast packets through Noise sessions | `ble_transport.dart` | Medium |
| 🔴 P0 | **C5** — Encrypt message storage at rest | `message_storage_service.dart` | Medium |
| 🟠 P1 | **C1** — Replace `Random()` with `Random.secure()` | `relay_controller.dart` | Trivial |
| 🟠 P1 | **H1** — Remove `localName` from BLE advertising | `ble_transport.dart` | Trivial |
| 🟠 P1 | **H3** — Add per-device rate limiting on incoming packets | `ble_transport.dart` | Small |
| 🟠 P1 | **H4** — Add decompression bomb protection | `compression.dart` | Small |
| 🟠 P1 | **H7** — Add max data length check at transport layer | `ble_transport.dart` | Trivial |
| 🟠 P1 | **H2** — Add Android `networkSecurityConfig` | `AndroidManifest.xml` | Small |
| 🟡 P2 | **M1** — Add length checks before all `sublist()` calls | Multiple files | Small |
| 🟡 P2 | **M2** — Wrap unguarded decode operations in `try/catch` | Multiple files | Small |
| 🟡 P2 | **C6** — Implement session re-keying when threshold is reached | `noise_session_manager.dart` | Medium |
| 🟡 P2 | **H6** — Use write-with-response for critical packet types | `ble_transport.dart` | Small |
| 🟡 P3 | **M4** — Enforce peripheral connection limits | `ble_transport.dart` | Medium |
| 🟡 P3 | **M3** — Persist trusted peers across restarts | `identity_manager.dart` | Medium |
| 🟢 P4 | **L1** — Treat 23-byte MTU fallback as hard error | `ble_transport.dart` | Trivial |

---

## Conclusion

The FluxonApp has a **strong cryptographic foundation** — the Noise XX implementation, key management, and secure storage are well-architected. The primary gap is at the **transport integration layer**: packets arrive with Ed25519 signatures but are never verified, and broadcasts bypass Noise encryption. Fixing C3, C4, and C2 would dramatically strengthen the security posture by closing the gap between "crypto primitives are correct" and "crypto is actually enforced end-to-end."

The message storage plaintext issue (C5) is the other critical gap — it undermines the encryption provided at the transport and group cipher layers by persisting decrypted messages in the clear.

All P0 items should be addressed before any production or beta release. P1 items are recommended for the next sprint. P2/P3 items can be tracked as backlog.
