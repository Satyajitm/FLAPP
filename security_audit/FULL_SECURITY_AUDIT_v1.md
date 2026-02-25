# FluxonApp — Full Security Audit Report v1
**Date:** 2026-02-25
**Auditors:** 4 parallel static-analysis agents
**Scope:** Entire codebase (crypto, BLE/mesh, storage/input validation, UI/features)
**Tests at time of audit:** 780 / 780 passing

---

## Executive Summary

Four specialized security agents audited the entire FluxonApp codebase in parallel, covering:
- **Crypto & Protocol Layer** — `lib/core/crypto/`, `lib/core/protocol/`, `lib/core/identity/`
- **BLE Transport & Mesh Layer** — `lib/core/transport/`, `lib/core/mesh/`
- **Data Storage & Input Validation** — message storage, group storage, binary protocol parsing, compression
- **UI & Feature Layer** — all features, providers, services, AndroidManifest, Info.plist

| Severity | Count |
|----------|-------|
| **Critical** | 9 |
| **High** | 20 |
| **Medium** | 17 |
| **Low / Info** | 19 |
| **Total** | **65** |

The codebase demonstrates strong security foundations from prior audits (v2.6 through v4.6), including constant-time comparisons, Argon2id key derivation, Noise XX, Ed25519 signing, and encrypted-at-rest message storage. The new findings focus on edge-case input validation, race conditions, UI/UX security gaps, and remaining architectural weaknesses.

---

## CRITICAL Findings

### C1: Peripheral Authentication Race Condition
**File:** `lib/core/transport/ble_transport.dart` (lines 676–695)
**Layer:** BLE/Transport

**Description:**
A peripheral client is added to `_authenticatedPeripheralClients` when Noise handshake message 3 is received, but `_noiseSessionManager.hasSession()` may not yet return `true` at that exact moment. The broadcast path checks `hasSession()` and falls through to send plaintext if false — creating a narrow window where plaintext packets are sent to an "authenticated" client.

**Exploit Scenario:**
Device X completes handshake message 3 and is marked authenticated. Before the session object is constructed in `NoiseSession.fromHandshake()`, a broadcast fires. `hasSession()` returns false, so `sendData = data` (plaintext) is used.

**Recommended Fix:**
Populate a separate `_readyPeripheralClients` set only after `_noiseSessionManager.hasSession(deviceId)` returns true. Never use `_authenticatedPeripheralClients` as a broadcast target directly.

---

### C2: Topology Poisoning via Unbounded Neighbor Claims
**File:** `lib/core/mesh/topology_tracker.dart` (lines 29–45)
**Layer:** Mesh

**Description:**
`updateNeighbors()` accepts `List<Uint8List> neighbors` with no internal size cap. Although `binary_protocol.dart` limits discovery packets to 10 neighbors at decode time, a direct call to `updateNeighbors()` bypasses this. A malicious peer claiming thousands of neighbors causes unbounded memory growth and exponential BFS complexity.

**Exploit Scenario:**
Attacker claims 10,000 neighbors (320 KB per claim). Next `computeRoute()` BFS explores millions of paths. Device freezes or crashes.

**Recommended Fix:**
Add a hard cap inside `TopologyTracker.updateNeighbors()`:
```dart
static const int _maxNeighborsPerClaim = 10;
if (neighbors.length > _maxNeighborsPerClaim) return;
```
Also add a BFS visited-node limit: `if (visited.length > 500) return null;`

---

### C3: Unencrypted Packet Metadata Broadcast
**File:** `lib/core/transport/ble_transport.dart` (lines 643–655)
**Layer:** BLE/Transport

**Description:**
`broadcastPacket()` sends packets with plaintext headers: source peer ID (32 bytes), packet type (0x02 = chat, 0x0A = location, 0x0E = emergency), and timestamp. Any BLE sniffer (Ubertooth, HackRF) within range can perform traffic analysis — correlating timing and types to infer conversation patterns and movement.

**Recommended Fix:**
Add an outer envelope encryption layer using XChaCha20-Poly1305 with a per-packet random nonce to encrypt the entire packet except a minimal routing header. Add dummy packets at random intervals to obscure traffic patterns.

---

### C4: Public Mutable Group Encryption Key
**File:** `lib/core/identity/group_manager.dart` (line 184), `lib/core/identity/group_cipher.dart`
**Layer:** Crypto/Identity

**Description:**
`FluxonGroup.key` is declared `final Uint8List key` — the reference is final but the bytes are mutable. Any code holding a reference to the group can corrupt the key in-place (`group.key[0] ^= 0xFF`), breaking all subsequent group encryption/decryption silently.

**Recommended Fix:**
Store the key as a `SecureKey` (libsodium-managed, non-copyable) or move it inside `GroupCipher` with no external accessor. At minimum, return `Uint8List.fromList(key)` (a copy) from any getter.

---

### C5: `HexUtils.decode()` Accepts Malformed Input
**File:** `lib/shared/hex_utils.dart` (lines 43–48)
**Layer:** Shared

**Description:**
`HexUtils.decode()` has no input validation:
1. Odd-length strings silently truncate: `"abc"` → 1 byte instead of error
2. Non-hex characters cause uncaught `FormatException` from `int.parse()`
3. No minimum/maximum length check

This propagates to `PeerId.fromHex()` — corrupted peer IDs can bypass identity matching if assertions are disabled in release builds.

**Recommended Fix:**
```dart
static Uint8List decode(String hex) {
  if (hex.isEmpty || hex.length % 2 != 0) {
    throw FormatException('Hex string must have even non-zero length, got ${hex.length}');
  }
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    throw FormatException('Hex string contains invalid characters');
  }
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
```

---

### C6: `MainActivity` Exported Without Restriction
**File:** `android/app/src/main/AndroidManifest.xml` (line 25)
**Layer:** UI/Android

**Description:**
`android:exported="true"` allows any app on the device to send arbitrary intents to MainActivity — enabling navigation to sensitive screens (emergency alert, group creation) without user interaction.

**Recommended Fix:**
Change to `android:exported="false"` unless the app uses deep links or intents from other apps. If exported is required, add `<intent-filter>` with strict action/category and validate all incoming intent data before use.

---

### C7: Passphrase Embedded Plaintext in QR Code
**File:** `lib/features/group/share_group_screen.dart` (line 23)
**Layer:** UI

**Description:**
QR code payload format is `fluxon:<joinCode>:<passphrase>`, embedding the full plaintext passphrase. QR codes can be captured via screenshot, screen recording, clipboard, or physical observation of the device screen.

**Recommended Fix:**
Option A: Remove passphrase from QR entirely — deliver out-of-band (verbal, separate secure channel).
Option B: Include only a commitment: `fluxon:<joinCode>:<BLAKE2b(passphrase || joinCode)>` — joining device confirms passphrase hash matches before attempting key derivation.

---

### C8: Passphrase Clipboard Exposure
**File:** `lib/features/group/share_group_screen.dart` (line 152)
**Layer:** UI

**Description:**
Clipboard contents are world-readable to any app with clipboard access. If the passphrase flows through the clipboard (via QR code sharing, copy-paste), it persists without expiry. Some Android/iOS versions allow background apps to read clipboard silently.

**Recommended Fix:**
- Never copy passphrase to clipboard
- If join code is copied, clear clipboard after 30 seconds:
```dart
Future.delayed(const Duration(seconds: 30), () => Clipboard.setData(const ClipboardData(text: '')));
```

---

### C9: Unhandled `FormatException` in `GroupManager.joinGroup()`
**File:** `lib/core/identity/group_manager.dart` (line 104)
**Layer:** Identity

**Description:**
`_cipher.decodeSalt(joinCode)` explicitly throws `FormatException` on invalid base32 input. The call site has no try/catch. A malformed join code (e.g., `"!@#$%"`) crashes the UI or propagates an uncaught exception.

**Recommended Fix:**
```dart
FluxonGroup joinGroup(String passphrase, {required String joinCode, String? groupName}) {
  final Uint8List salt;
  try {
    salt = _cipher.decodeSalt(joinCode);
  } on FormatException {
    throw ArgumentError('Invalid join code format');
  }
  // ...
}
```

---

## HIGH Findings

### H1: Rate Limit Window Boundary Race
**File:** `lib/core/transport/ble_transport.dart` (lines 722–733)

Fixed-window rate limit (100 pps) allows 2× burst at window boundary. Coordinated attacker sends 100 packets at 999ms, resets window at 1000ms, sends another 100 — delivering 200 packets in ~1ms. Replace with token bucket or sliding window.

---

### H2: Peripheral Connection Limit Race Condition
**File:** `lib/core/transport/ble_transport.dart` (lines 249–257)

Concurrent write callbacks from multiple new devices both pass the `_peripheralClients.length >= config.maxConnections` check simultaneously, allowing more connections than `maxConnections`. Use a synchronized queue or atomic check-and-add.

---

### H3: 30-Second Handshake Timeout Enables Slowloris
**File:** `lib/core/transport/ble_transport.dart` (lines 565–585)

Unauthenticated peripheral clients may occupy all 7 connection slots for up to 30 seconds by sending occasional bytes to reset the timer. Legitimate peers see "connection limit reached."

**Fix:** Reduce timeout to 5–10 seconds. Disconnect immediately if no valid handshake message 1 received within 3 seconds.

---

### H4: Handshake Exception Not Caught at Call Site
**File:** `lib/core/transport/ble_transport.dart` (line 839)

`_noiseSessionManager.processHandshakeMessage()` can throw (e.g., invalid signing key length). The call site at line 839 has no try/catch — malformed handshake from attacker crashes packet processing.

**Fix:**
```dart
try {
  final result = _noiseSessionManager.processHandshakeMessage(fromDeviceId, packet.payload);
  // ...
} catch (e) {
  _log('Handshake error from $fromDeviceId: $e');
  _disconnectPeer(fromDeviceId);
}
```

---

### H5: 32-Bit Effective Nonce in Noise Transport Phase
**File:** `lib/core/crypto/noise_protocol.dart` (lines 91–122, 125–175)

The Noise transport phase sends a 4-byte nonce and reconstructs an 8-byte one on receive. Nonce wraps at 2^32 messages. Sessions rekey at 1,000,000 messages — providing protection in practice, but the rekey threshold should be lowered to 500,000 to provide additional margin.

---

### H6: Unencrypted Topology and Discovery Packets
**Files:** `lib/core/protocol/message_types.dart`, `lib/core/protocol/binary_protocol.dart`

`discovery` (0x08) and `topologyAnnounce` (0x03) packets are broadcast unencrypted. A passive BLE observer learns the full mesh topology, all peer IDs, and can track device movement through topology changes — without joining any group.

**Fix:** Encrypt topology payloads with a mesh-wide shared secret, or introduce a discovery encryption layer using ephemeral keys.

---

### H7: No TOFU Signing Key Verification
**File:** `lib/core/crypto/noise_session_manager.dart` (lines 176–206, 213–240)

The Ed25519 signing key received in a Noise handshake is accepted as long as it is 32 bytes and non-zero — no check against previously seen keys for the same peer. A MitM on the first handshake can inject the attacker's signing key; subsequent packets are signed by the attacker and pass verification.

**Fix:** Implement Trust-On-First-Use: store signing key fingerprint after first handshake, reject mismatches on subsequent connections:
```dart
final knownKey = identityManager.getExpectedSigningKey(remotePeerId);
if (knownKey != null && !bytesEqual(knownKey, remoteSigningKey)) {
  throw Exception('Signing key mismatch — possible MitM');
}
```

---

### H8: Silent Receipt Batch Drop
**File:** `lib/core/protocol/binary_protocol.dart` (line 220)

`encodeBatchReceiptPayload()` clamps to 11 receipts and silently discards the rest. Delivery indicators (double-ticks) are permanently lost for messages beyond the first 11 in a flush cycle.

**Fix:** Return the count encoded; caller loops until all receipts sent:
```dart
while (pendingReceipts.isNotEmpty) {
  final sent = encodeAndSendBatch(pendingReceipts.take(11).toList());
  pendingReceipts.removeRange(0, sent);
  await Future.delayed(const Duration(milliseconds: 100));
}
```

---

### H9: No Rate Limiting on Argon2id Group Operations
**File:** `lib/core/identity/group_manager.dart` (lines 63, 99–103)

`createGroup()` and `joinGroup()` invoke Argon2id with `opsLimitModerate` (64 MB RAM, ~0.5–1s CPU) with no rate limit. An attacker can loop calls to DoS the device CPU/battery, or brute-force passphrases offline after capturing a salt.

**Fix:** Limit to 3 group operations per minute. Show progress UI during derivation.

---

### H10: Ephemeral Private Key in Public Field
**File:** `lib/core/crypto/noise_protocol.dart` (line 385)

`NoiseHandshakeState.localEphemeralPrivate` is a public mutable field. A debugger, Dart reflection, or code injection can read it during the handshake window and derive the session shared secret.

**Fix:** Make field private: `Uint8List? _localEphemeralPrivate;`. Provide `@visibleForTesting` getter for test access only (no production getter).

---

### H11: Replay Window Only 1024 Messages
**File:** `lib/core/crypto/noise_protocol.dart` (lines 57–77)

After 1024 messages gap, old nonces fall outside the sliding window and can be replayed. At moderate traffic (10 msg/sec), this window is only ~100 seconds.

**Fix:** Increase `replayWindowSize` to 4096. Minimal memory cost (512 bytes instead of 128).

---

### H12: Unhandled Exceptions in `KeyStorage._decodeStoredKey()`
**File:** `lib/core/crypto/keys.dart` (lines 53–65)

If hex fallback in `_decodeStoredKey()` receives invalid characters, `HexUtils.decode()` throws an uncaught exception — crashing app startup when loading identity keys from `flutter_secure_storage`.

**Fix:**
```dart
Uint8List _decodeStoredKey(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    try {
      return HexUtils.decode(value);
    } catch (_) {
      throw FormatException('Stored key is neither valid base64 nor hex');
    }
  }
}
```

---

### H13: Location Broadcast Without Per-Peer Consent
**File:** `lib/features/location/location_controller.dart` (line 62)

GPS coordinates are broadcast to all group members with no granular consent. A malicious group member can collect location history and track the user indefinitely.

**Fix:** Add per-peer location-sharing whitelist. Warn user when new peers join the group while location is active. Consider rounding coordinates to 500m precision.

---

### H14: Passphrase Minimum Only 8 Characters
**Files:** `lib/features/group/create_group_screen.dart:33`, `lib/features/group/join_group_screen.dart:50`

8-character passphrases are vulnerable to offline dictionary attacks after capturing the Argon2id salt from a join code.

**Fix:** Increase minimum to 12 characters. Add entropy/strength indicator. Reject passphrases from a common-password list.

---

### H15 & H16: Error Enumeration and No Rate Limiting on Join
**File:** `lib/features/group/join_group_screen.dart` (lines 77–81)

Different error states reveal whether the join code or passphrase is wrong. Additionally, there is no delay or lockout between failed attempts, enabling rapid passphrase enumeration.

**Fix:** Return a single generic error: `"Unable to join group. Check your code and passphrase."` Apply exponential backoff (1s, 2s, 4s…) and lock for 30s after 5 failures.

---

### H17: `TextEditingController` Passphrase Not Zeroed on Dispose
**Files:** `lib/features/group/join_group_screen.dart:29`, `lib/features/group/create_group_screen.dart:22`

Dart `String` objects are immutable and garbage-collected non-deterministically. The passphrase string from the controller stays in heap memory after `dispose()` until GC runs.

**Fix:** Call `_passphraseController.clear()` immediately before `dispose()`. Use a custom `SecureTextEditingController` that zeros internal buffer on clear.

---

### H18: No Screenshot / Screen Recording Protection on QR Screen
**File:** `lib/features/group/share_group_screen.dart`

QR codes containing passphrases can be captured via system screenshot or screen recording. Android `FLAG_SECURE` is not set.

**Fix:** Apply `FLAG_SECURE` to the window when showing the QR screen:
```dart
// In platform channel or via flutter_windowmanager package
await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
```
Remove the flag when leaving the screen.

---

### H19: `HexUtils.decode()` Odd-Length Silent Truncation (Alias of C5)
See **C5** above. Listed separately as a high-severity downstream impact on peer ID handling.

---

### H20: No Per-Peer Handshake State Cleanup on Disconnect
**File:** `lib/core/transport/ble_transport.dart` (lines 520–545)

On BLE disconnect, `_noiseSessionManager` state for the peer is not explicitly cleared. Rapid connect/disconnect cycles (100+) accumulate stale `_PeerState` objects until LRU eviction, causing memory pressure.

**Fix:** Add a `clearPeer(deviceId)` method to `NoiseSessionManager` that calls `dispose()` on the peer's handshake/session and removes the entry. Call it on disconnect.

---

## MEDIUM Findings

### M1: Silent Plaintext→Encrypted Migration Masks Prior Compromise
**File:** `lib/core/services/message_storage_service.dart` (lines 171–196)

When decryption fails, code silently reads plaintext and re-encrypts without notifying the user. If the device was previously compromised and plaintext messages were written, the user never learns of the exposure.

**Fix:** Log a security warning via `SecureLogger` and surface an in-app notification when plaintext messages are migrated.

---

### M2: Display Name Homoglyph / Dangerous Unicode
**Files:** `lib/core/identity/user_profile_manager.dart`, `lib/core/protocol/binary_protocol.dart`

Display names allow homoglyphs (Cyrillic А vs Latin A), right-to-left override (U+202E), zero-width characters (U+200B), and combining diacriticals — enabling impersonation attacks.

**Fix:** Validate and reject names containing codepoints in dangerous ranges (U+200B–U+200F, U+202A–U+202E, U+0300–U+036F). Apply NFKC normalization. Consider restricting to ASCII for initial implementation.

---

### M3: No Rate Limit on Argon2id Calls (UI Layer)
**File:** `lib/core/identity/group_manager.dart`
See H9. Rate limiting must also be enforced in the UI so the user cannot initiate rapid join retries.

---

### M4: Group Name Length Unbounded in Storage
**File:** `lib/core/identity/group_storage.dart`

No maximum length check on the `name` parameter before persisting to `flutter_secure_storage`. Extremely long names could cause memory pressure on load.

**Fix:** Enforce `if (name.length > 128) throw ArgumentError(...)`.

---

### M5: Topology Route Cache Stale Entries
**File:** `lib/core/mesh/topology_tracker.dart` (lines 156–174)

5-second route cache TTL is too long for rapidly changing BLE mesh. A disconnected relay can cause packets to be routed to a broken path for up to 5 seconds. Consider reducing TTL to 1–2 seconds or clearing the entire cache on any topology mutation.

---

### M6: Gossip Sync Amplification via Sybil Peers
**File:** `lib/core/mesh/gossip_sync.dart` (lines 81–124)

10 Sybil peers each requesting gossip sync from one victim → 110 outgoing packets per 60-second window. No global gossip sync budget exists.

**Fix:** Add global cap: max 50 gossip response packets per 60 seconds across all peers.

---

### M7: Missing TTL Upper-Bound Validation in Packet Decoder
**File:** `lib/core/protocol/packet.dart` (lines 114–149)

`FluxonPacket.decode()` reads TTL but does not validate it against `maxTTL`. A packet with TTL=255 is accepted. While relay controller clamps on relay, the raw packet with inflated TTL is delivered to the app layer.

**Fix:** Clamp or reject at decode: `if (ttl > maxTTL) return null;`

---

### M8: Receipt Timestamp Can Be Forged
**File:** `lib/core/protocol/binary_protocol.dart` (lines 184–210)

`ReceiptPayload.originalTimestamp` is not validated against the original message's timestamp. Attacker can forge receipts with arbitrary timestamps, corrupting the delivery timeline.

**Fix:** When receiving a receipt, verify `|receiptTimestamp - originalMessageTimestamp| < 5000ms`.

---

### M9: Unbounded Emergency Message Field
**File:** `lib/core/protocol/binary_protocol.dart` (lines 108–123)

Emergency payload message field has no explicit length cap before allocation. The 512-byte packet limit provides an implicit bound, but no explicit check is made.

**Fix:** `if (message.length > 256) throw ArgumentError(...)` before encoding.

---

### M10: Argon2id Cache Key Only 16 Bytes (128-bit)
**File:** `lib/core/identity/group_cipher.dart` (lines 137–144)

BLAKE2b hash used as derivation cache key is only 16 bytes. Birthday collision probability is 1-in-2^64 — safe in practice but sub-optimal.

**Fix:** Increase to 32 bytes: `outLen: 32`.

---

### M11: Passphrase Bytes in GC Heap During Group Derivation
**File:** `lib/core/identity/group_cipher.dart` (lines 137–144)

`Uint8List.fromList(utf8.encode(passphrase) + salt)` creates a plaintext intermediate that is not zeroed after hashing.

**Fix:** Zero `keyInput` immediately after `genericHash()`:
```dart
for (int i = 0; i < keyInput.length; i++) keyInput[i] = 0;
```

---

### M12: TOCTOU in Permission Check
**File:** `lib/core/device/device_services.dart` (lines 61–72)

Permission is checked, user is prompted, but the result is compared against the *original* (pre-prompt) `permission` variable. If user denies in the dialog, stale variable may still show `denied` (not `deniedForever`), and code proceeds incorrectly.

**Fix:** Re-check permission after the request resolves:
```dart
final finalPerm = await Geolocator.checkPermission();
if (finalPerm != LocationPermission.whileInUse && finalPerm != LocationPermission.always) return false;
```

---

### M13: Display Name Not Sanitized Before JSON Transmission
**File:** `lib/features/chat/chat_controller.dart` (line 186)

Display names containing `"` or `\n` are embedded directly in JSON payload. While `json.encode()` is used for the full payload, a name like `Alice","malicious":"field}` could cause parsing issues on non-standard receivers.

**Fix:** Validate on receive: use strict JSON schema; reject names containing control characters or JSON structural characters.

---

### M14: Group State Not Atomically Synchronized
**File:** `lib/features/group/join_group_screen.dart` (lines 71–76), `lib/core/providers/group_providers.dart`

`GroupManager.joinGroup()` and `ref.read(activeGroupProvider.notifier).state = group` are two separate operations. A rebuild between them can expose an inconsistent state where the group exists in `GroupManager` but not in Riverpod.

**Fix:** Wrap both mutations in a single provider action or use `ref.invalidate(activeGroupProvider)` to force re-read.

---

### M15: Emergency Alert Coordinates Not Precision-Reduced
**File:** `lib/features/emergency/emergency_controller.dart` (line 178)

Full-precision GPS coordinates are broadcast in emergency alerts, permanently revealing exact location to all group members and relayed peers.

**Fix:** Round coordinates to 3 decimal places (~100m precision) before broadcast.

---

### M16: Foreground Service Notification Discloses Mesh Activity
**File:** `lib/core/services/foreground_service_manager.dart` (lines 47–75)

Notification visible on lock screen reveals that mesh relay is active, disclosing app usage to observers.

**Fix:** Use generic notification text such as "FluxonApp active" without mentioning BLE or mesh.

---

### M17: Signing Key Validation Missing Rate Limit for Failed Attempts
**File:** `lib/core/crypto/noise_session_manager.dart` (lines 110–128)

Invalid signing key rejections (wrong length, all-zero) are not counted against the global handshake rate limit. Attacker can send unlimited valid Noise handshakes with invalid signing keys, causing repeated exceptions.

**Fix:** Increment handshake failure counter on signing key rejection; apply same rate limit as other handshake failures.

---

## LOW / INFO Findings

| # | Finding | File |
|---|---------|------|
| L1 | Missing `context.mounted` check before `ScaffoldMessenger` in share screen | `share_group_screen.dart:153` |
| L2 | `catch (e)` in join group swallows real exception without logging | `join_group_screen.dart:77` |
| L3 | No cooldown between emergency alert broadcasts (user can spam) | `emergency_controller.dart:143` |
| L4 | Received display name length not validated (attacker can send 10 KB name) | `binary_protocol.dart` |
| L5 | Error messages reveal exact input constraint (e.g., "must be 26 chars") | Multiple screens |
| L6 | Deep link (`fluxon://`) source not validated | `app.dart`, `join_group_screen.dart` |
| L7 | No audit log of group create/join/leave operations | `group_manager.dart` |
| L8 | GPS initialization errors silently ignored in location screen | `location_screen.dart:41` |
| L9 | Chat message cap (200) not communicated to user | `chat_controller.dart:75` |
| L10 | `flutter_secure_storage` not explicitly encrypted on Android <6 | `user_profile_manager.dart` |
| L11 | `@visibleForTesting` missing on public crypto fields | `noise_protocol.dart:382` |
| L12 | Identity trust list JSON has no version field (migration impossible) | `identity_manager.dart:116` |
| L13 | Location coordinates not range-validated (lat/lng can be out of bounds) | `binary_protocol.dart:92` |
| L14 | Malformed UTF-8 in chat payload returns empty message silently | `binary_protocol.dart:46` |
| L15 | Relay timing jitter is observable (topology fingerprinting) | `relay_controller.dart` |
| L16 | `TopologyTracker._sanitize()` does not reject all-zero peer IDs | `topology_tracker.dart:187` |
| L17 | Peripheral client cleanup latency up to 90s (30s interval + 60s cutoff) | `ble_transport.dart:269` |
| L18 | Nonce collision in group encryption astronomically unlikely (INFO only) | `group_cipher.dart:80` |
| L19 | `PeerId` hash code uses only 4 bytes (32-bit birthday collision at ~65K peers) | `peer_id.dart:16` |

---

## Remediation Roadmap

### Phase 1 — Immediate (this sprint)
1. `HexUtils.decode()` — add input validation (C5 / H19)
2. `GroupManager.joinGroup()` — wrap `decodeSalt()` in try/catch (C9)
3. `KeyStorage._decodeStoredKey()` — catch all decode exceptions (H12)
4. `AndroidManifest.xml` — `android:exported="false"` on MainActivity (C6)
5. Passphrase removed or hashed in QR payload (C7 / C8)
6. `_handleHandshakePacket()` — wrap `processHandshakeMessage()` in try/catch (H4)
7. `TopologyTracker.updateNeighbors()` — internal neighbor count cap (C2)

### Phase 2 — High Priority (next 2 sprints)
1. Wrap `FluxonGroup.key` in `SecureKey` / make immutable (C4)
2. Peripheral auth race — populate `_readyClients` only after session confirmed (C1)
3. TOFU signing key pinning in `NoiseSessionManager` (H7)
4. Passphrase minimum → 12 characters + strength indicator (H14)
5. Generic error messages on join failure + exponential backoff (H15 / H16)
6. `_passphraseController.clear()` before dispose (H17)
7. `FLAG_SECURE` on QR / share screens (H18)
8. `clearPeer(deviceId)` on BLE disconnect (H20)
9. Rate limit on Argon2id group operations (H9)
10. Increase replay window to 4096 (H11)
11. Make `localEphemeralPrivate` private (H10)

### Phase 3 — Medium Priority (next quarter)
1. Display name Unicode sanitization / homoglyph rejection (M2 / M13)
2. Fix silent receipt batch overflow (H8)
3. TTL validation in `FluxonPacket.decode()` (M7)
4. Location precision reduction to 100m for broadcasts (M15)
5. Gossip sync global budget (M6)
6. Emergency coordinate truncation (M9)
7. Atomic group state updates (M14)
8. Re-check permission after request (M12)
9. Receipt timestamp validation (M8)
10. Log signing key changes; surface security warnings (M1 / M17)

### Phase 4 — Ongoing / Low Priority
Address LOW / INFO findings (L1–L19) in order of user-facing impact.

---

## Comparison with Previous Audits

| Audit | Date | Findings Addressed |
|-------|------|--------------------|
| Security Hardening v2.6 | Prior | 35 issues (memory protection, passphrase storage, payload size, rate limiting, Argon2id) |
| Performance & Correctness v3.0 | Prior | 18 fixes (BLE duty cycle, topology cache, batch writes, parallel init) |
| Security Hardening v4.0 | 2026-02-24 | 28 BLE security findings (Noise per-peer, sig verification, rate limiting, at-rest encryption) |
| Crypto Security Audit v4.5 | 2026-02-25 | Noise SHA-256, constant-time comparisons, group cipher AD, key storage base64 |
| Crypto Security Audit v4.6 | 2026-02-25 | Noise rekey paths, handshake dispose, PKCS#7 constant-time unpad, group key base64 |
| **This Audit (v1)** | **2026-02-25** | **65 new findings across all layers** |

---

*Report generated by automated static-analysis agents. All findings are based on read-only code review and threat modeling. Dynamic testing (fuzzing, on-device protocol analysis) would provide additional validation.*
