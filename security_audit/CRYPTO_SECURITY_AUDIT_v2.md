# 🔐 FluxonApp — Cryptography Layer In-Depth Security Audit v2

**Date:** 2026-02-25  
**Auditor:** Deep Manual Analysis (v2 — Full Re-Audit)  
**Scope:** All files under `lib/core/crypto/`, `lib/core/identity/`, integration points in `lib/core/transport/ble_transport.dart`, `lib/core/protocol/`, `lib/core/mesh/mesh_service.dart`, `lib/core/services/message_storage_service.dart`  
**Audit Type:** White-box cryptographic review (full source access)  
**Prior Audit:** `CRYPTO_SECURITY_AUDIT.md` (v1, 2026-02-25)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Status of v1 Findings](#status-of-v1-findings)
3. [New or Upgraded Findings](#new-or-upgraded-findings)
4. [Deep Technical Analysis by Component](#deep-technical-analysis-by-component)
5. [Attack Surface Map](#attack-surface-map)
6. [Exploit Scenarios](#exploit-scenarios)
7. [Recommendations & Remediation](#recommendations--remediation)
8. [Positive Security Properties](#positive-security-properties)

---

## Executive Summary

This is a **complete re-audit** of the FluxonApp cryptography layer following the v1 audit. Several v1 findings have been **remediated** since the original audit. This v2 audit identifies the current state of each v1 finding, discovers **new vulnerabilities**, and provides deeper analysis of the attack surface.

### Changes Since v1

The codebase shows evidence of significant hardening since v1:
- ✅ **CRIT-C3 (Fixed):** Signing key cache now uses constant-time XOR comparison with `_cachedKeyBytes`
- ✅ **HIGH-C2 (Fixed):** `GroupCipher.clearCache()` implemented and called from `GroupManager.leaveGroup()`
- ✅ **HIGH-C3 (Fixed):** `bytesEqual` in `hex_utils.dart` now uses XOR accumulator (constant-time)
- ✅ **HIGH-C4 (Fixed):** Keys stored as base64, with hex migration logic for backward compatibility
- ✅ **MED-C1 (Fixed):** Group encryption now accepts `additionalData` parameter, bound to `MessageType`
- ✅ **MED-C2 (Fixed):** `NoiseSession.encrypt()` now increments `_messagesSent` **after** success
- ✅ **MED-C3 (Fixed):** Group ID derived from Argon2id output, not raw passphrase
- ✅ **MED-C4 (Fixed):** LRU eviction now calls `dispose()` on evicted handshake/session states
- ✅ **MED-C5 (Fixed):** `_cachedGroupKeyHash` uses BLAKE2b hash, not raw key bytes
- ✅ **MED-C6 (Partially Fixed):** Direct peer signing key verification added; relayed packets still accepted provisionally
- ✅ **LOW-C1 (Fixed):** `_sha256` now uses `pkg_crypto.sha256.convert()`, not `genericHash`
- ✅ **LOW-C4 (Fixed):** `MessageStorageService` caches `SecureKey` wrapper, disposes in `dispose()`
- ✅ **CRIT-C2 (Fixed):** Central broadcast path now returns early when `encrypt()` returns `null`

### Current Risk Summary

| Severity | Count | Description |
|----------|-------|-------------|
| 🔴 **CRITICAL** | 2 | Exploitable flaws that break confidentiality or interoperability guarantees |
| 🟠 **HIGH** | 4 | Significant weaknesses that weaken the security model under realistic attacks |
| 🟡 **MEDIUM** | 5 | Design issues exploitable under elevated threat models |
| 🟢 **LOW** | 3 | Minor issues representing defense-in-depth gaps |
| ℹ️ **INFO** | 4 | Observations and hardening recommendations |

---

## Status of v1 Findings

| v1 ID | v1 Severity | Finding | v2 Status |
|-------|-------------|---------|-----------|
| CRIT-C1 | 🔴 Critical | Wrong ChaCha20 variant (original vs IETF) | 🔴 **STILL OPEN** — see analysis below |
| CRIT-C2 | 🔴 Critical | Rekey sends plaintext in central broadcast path | ✅ **FIXED** — `return` guard added (line 654) |
| CRIT-C3 | 🔴 Critical | Weak hash for signing key cache invalidation | ✅ **FIXED** — constant-time XOR comparison |
| HIGH-C1 | 🟠 High | Ephemeral keys in GC heap | 🟠 **STILL OPEN** — fundamental Dart limitation |
| HIGH-C2 | 🟠 High | Group key cache never evicted | ✅ **FIXED** — `clearCache()` implemented |
| HIGH-C3 | 🟠 High | Non-constant-time byte comparison | ✅ **FIXED** — XOR accumulator in `bytesEqual` |
| HIGH-C4 | 🟠 High | Private key hex encoding in storage | ✅ **FIXED** — base64 encoding + migration |
| HIGH-C5 | 🟠 High | No handshake response replay protection | 🟠 **STILL OPEN** — see upgrade below |
| MED-C1 | 🟡 Medium | Group encryption has no associated data | ✅ **FIXED** — `additionalData: ad` parameter |
| MED-C2 | 🟡 Medium | Message counter incremented before success | ✅ **FIXED** — post-success increment |
| MED-C3 | 🟡 Medium | Group ID allows fast passphrase brute-force | ✅ **FIXED** — derived from Argon2id output |
| MED-C4 | 🟡 Medium | LRU eviction doesn't dispose handshake state | ✅ **FIXED** — `dispose()` called on eviction |
| MED-C5 | 🟡 Medium | Raw group key in GC heap for comparison | ✅ **FIXED** — uses BLAKE2b hash |
| MED-C6 | 🟡 Medium | Silent acceptance of unverified mesh packets | ⚠️ **PARTIAL** — direct peers blocked, relayed still accepted |
| LOW-C1 | 🟢 Low | `_sha256` uses BLAKE2b instead of SHA-256 | ✅ **FIXED** — uses `pkg_crypto.sha256` now |
| LOW-C2 | 🟢 Low | Documentation says SHA-256, uses BLAKE2b | ✅ **FIXED** — documentation updated |
| LOW-C3 | 🟢 Low | Public `FluxonGroup.key` field | 🟢 **STILL OPEN** |
| LOW-C4 | 🟢 Low | SecureKey allocated per encrypt call | ✅ **FIXED** — cached `SecureKey` wrapper |

**Fix Rate: 14 of 18 findings addressed (78%)**

---

## New or Upgraded Findings

### 🔴 CRITICAL

---

#### CRIT-N1: ChaCha20-Poly1305 Original Variant Still Used — Noise Spec Non-Compliance (carries over from CRIT-C1)

**Files:** `lib/core/crypto/noise_protocol.dart`, lines 98–107  
**CVSS Estimate:** 8.1 (High)

**Current Code:**
```dart
// Line 99: 8-byte nonce built for original ChaCha20-Poly1305
_nonceBufferData.setUint64(0, currentNonce, Endian.big);

// Lines 102-107: STILL uses original variant
final ciphertext = sodium.crypto.aeadChaCha20Poly1305.encrypt(
  message: plaintext,
  nonce: _nonceBuffer,
  key: _key!,
  additionalData: ad,
);
```

**Why This Is Still Critical:**
1. The Noise Protocol specification (`Noise_XX_25519_ChaChaPoly_SHA256`) explicitly mandates **RFC 7539 ChaCha20-Poly1305** (IETF variant, 12-byte nonce).
2. The original DJB variant uses an **8-byte nonce** with a different internal counter/block structure.
3. This makes the implementation **incompatible with any standards-compliant Noise library** (e.g., noise-protocol in Node.js, NoiseSocket, WireGuard's Noise).
4. The `_sha256` fix (LOW-C1) changed the hash to real SHA-256, which is correct per spec. But the cipher is still wrong, so the implementation is halfway between spec-compliant and custom.
5. The 8-byte nonce code comment at line 68 states: *"aeadChaCha20Poly1305IETF (12-byte) C function is not separately wrapped"* — this was true for older sodium_libs versions but **sodium_libs 2.x does wrap `aeadChaCha20Poly1305IETF`** via `sodium.crypto.aead` (which uses IETF by default).

**Impact:**
- ❌ Complete interoperability failure with any future desktop/web Noise client
- ⚠️ The Noise security proof depends on IETF ChaChaPoly properties; the original variant has different nonce rotation semantics
- ⚠️ A future developer adding a companion app with standard Noise would silently produce garbage handshakes

**Remediation:**
```dart
// Replace aeadChaCha20Poly1305 with aead (which defaults to IETF)
// OR use aeadChaCha20Poly1305IETF explicitly.
// Update nonce buffer to 12 bytes per Noise spec:
// noise_nonce = 4 zero bytes || 8-byte big-endian counter
final _nonceBuffer = Uint8List(12); // IETF nonce is 12 bytes
// Set counter in the lower 8 bytes:
_nonceBufferData.setUint64(4, currentNonce, Endian.big);
```

---

#### CRIT-N2: `sendPacket` in `BleTransport` Sends Plaintext When Noise Session is Missing (No `hasSession` Enforcement)

**File:** `lib/core/transport/ble_transport.dart`, lines 609–618  
**CVSS Estimate:** 7.8 (High)

**Current Code:**
```dart
// sendPacket, line 609-618:
var encodedData = packet.encodeWithSignature();
if (_noiseSessionManager.hasSession(deviceId)) {
  final ciphertext = _noiseSessionManager.encrypt(encodedData, deviceId);
  if (ciphertext != null) {
    encodedData = ciphertext;
    _log('Encrypted packet for $peerHex');
  }
  // ⚠️ If ciphertext is null (rekey), encodedData is STILL the plaintext!
}
// ⚠️ If no session exists, encodedData is unencrypted plaintext!
await char.write(encodedData, withoutResponse: !isReliable);
```

**Exploit Scenario:**
1. **Race-condition during rekey:** If `hasSession()` returns `true` but `encrypt()` returns `null` (rekey threshold reached), the plaintext `encodedData` is sent over BLE.
2. **Pre-handshake window:** Before the Noise handshake completes (there's always a small window after connection), any directed `sendPacket` call sends plaintext.
3. **Session teardown race:** If `removeSession` is called concurrently (e.g. BLE disconnect handler fires), `hasSession` returns `false` and plaintext is sent.

**The `broadcastPacket` method was correctly patched** (line 654: `if (encrypted == null) return;`), but `sendPacket` has the **same unfixed pattern**.

**Impact:** Unencrypted directed messages sent over BLE, readable by passive sniffers.

**Remediation:**
```dart
var encodedData = packet.encodeWithSignature();
if (_noiseSessionManager.hasSession(deviceId)) {
  final ciphertext = _noiseSessionManager.encrypt(encodedData, deviceId);
  if (ciphertext == null) {
    _log('Session needs rekey for $peerHex — skipping send');
    return false; // Don't send plaintext
  }
  encodedData = ciphertext;
} else {
  // No session = no encryption. Only allow handshake packets unencrypted.
  if (packet.type != MessageType.handshake) {
    _log('No session for $peerHex — skipping non-handshake send');
    return false;
  }
}
```

---

### 🟠 HIGH

---

#### HIGH-N1: Signing Key Not Verified Against Any Trust Anchor — Trivial MITM on First Contact

**Files:** `lib/core/crypto/noise_session_manager.dart`, lines 176–201; `lib/core/identity/identity_manager.dart`  
**CVSS Estimate:** 7.0 (High)

**Description:**  
The Ed25519 signing public key is exchanged as the **handshake payload** inside Noise messages 2 and 3. After the handshake completes, the signing key is cached and used to verify subsequent packet signatures. However:

1. **No verification of the signing key's binding to the DH static key.** An attacker who can perform a MITM on the Noise handshake (positioned between two peers before first contact) can inject their own signing key as the payload.
2. The Noise XX pattern authenticates the **static DH public keys** (via encrypted `s` tokens), but the **signing key in the payload** is only authenticated by the AEAD encryption of the Noise handshake message — it is **not cryptographically bound** to the static key.
3. There is no Trust-On-First-Use (TOFU) verification triggered. `IdentityManager.trustPeer` is never called after handshake completion. The `_trustedPeers` set is loaded/saved but **never populated** from the handshake flow.

**The Noise XX handshake prevents classical MITM** (the attacker would need the legitimate peer's static private key). But if an attacker compromises the BLE MAC advertising layer and intercepts message 1 before the real peer sees it, they can establish their own session and inject an arbitrary signing key.

**Impact:** The signing key is implicitly trusted without verification; TOFU is implemented but not wired up.

**Remediation:**
1. Derive the signing public key deterministically from the static key (e.g., `Ed25519_publickey = convert(X25519_publickey)`), OR
2. Sign the signing public key with the static key and include the signature in the payload, OR
3. Wire up `IdentityManager.trustPeer()` after the first handshake and `isTrusted()` checks for subsequent connections. Alert the user if a known peer's signing key changes.

---

#### HIGH-N2: No Session Binding Between BLE Connection and Noise Session — Session Hijack via MAC Spoofing

**File:** `lib/core/transport/ble_transport.dart`, lines 48-54; `lib/core/crypto/noise_session_manager.dart`  
**CVSS Estimate:** 6.5 (Medium-High)

**Description:**  
The `NoiseSessionManager` keys sessions by BLE device ID (MAC address). On Android, BLE MAC addresses can be **randomized and rotated** by the remote device. If an attacker:

1. Sniffs the BLE MAC used by Device A during its connection to Device B
2. Waits for Device A to disconnect
3. Spoofs Device A's MAC address and connects to Device B

Device B's `_handleIncomingData` will attempt `_noiseSessionManager.decrypt(data, spoofedDeviceId)`. Since Device A's session was removed on disconnect (line 521: `_noiseSessionManager.removeSession(deviceId)`), the decrypt will fail and the packet is dropped. **This path is safe.**

However, there's a **subtle race condition**: if the attacker connects **before** the disconnect handler fires (BLE disconnect detection is async and can lag up to 30 seconds on Android), the attacker's writes will go through the established session's decrypt attempt. Since the attacker doesn't have the session keys, decryption fails. But this generates a `NoiseException` that is caught and logged — the attacker can use the **timing of these log emissions** to probe whether a session exists.

**More critically:** The `_peripheralClients` map (line 70) tracks peripheral connections by device ID. If the attacker uses a spoofed MAC to connect as a peripheral client, they can exhaust the `maxConnections` limit (line 251) without triggering the Noise handshake rate limiter (which only fires on actual handshake message processing).

**Impact:** Connection slot exhaustion via MAC spoofing; timing oracle on session existence.

**Remediation:**
- Enforce handshake completion before counting a peripheral client toward the connection limit
- Add a connection attempt rate limiter keyed by IP/connection-level identifiers (where available)
- Consider BLE random address resolution via IRK (Identity Resolving Key) if available

---

#### HIGH-N3: `IdentityManager` Private Keys Persist in Dart Heap for Full App Lifetime — No `SecureKey` Wrapper

**File:** `lib/core/identity/identity_manager.dart`, lines 15-18  
**CVSS Estimate:** 5.5 (Medium)

**Description:**

```dart
Uint8List? _staticPrivateKey;      // 32-byte Curve25519 private key
Uint8List? _signingPrivateKey;     // 64-byte Ed25519 private key
```

These private keys are loaded once during `initialize()` and remain in the Dart GC heap for the **entire app lifetime**. Unlike `SecureKey` (which uses `mlock` to prevent swapping and is zeroed on `dispose`), `Uint8List` is:

1. **Subject to GC compaction** — moved by the garbage collector, leaving copies in old memory pages
2. **Swappable to disk** — on low-memory conditions, the OS may swap Dart heap pages to disk
3. **Not zeroed on dispose** — `resetIdentity()` nulls the reference but doesn't zero the bytes

The `resetIdentity()` method (line 92) sets fields to `null` but does **not** zero the `Uint8List` contents before discarding. The original bytes will persist in the GC heap until the memory page is reclaimed and overwritten.

This is upgraded from INFO-C3 to HIGH because:
- The signing private key (64 bytes) is **used on every outbound packet** via `Signatures.sign()`
- The static private key is **used for every new handshake** via `NoiseSessionManager`
- On a rooted device, these keys are **trivially extractable** via `/proc/pid/mem`

**Impact:** Long-term private key exposure on compromised/rooted devices.

**Remediation:**
```dart
// Store as SecureKey instead of Uint8List
SecureKey? _staticPrivateKey;
SecureKey? _signingPrivateKey;

// In resetIdentity():
_staticPrivateKey?.dispose();  // mlock'd memory is zeroed
_signingPrivateKey?.dispose();
```

---

#### HIGH-N4: No Automatic Re-Handshake After Rekey Threshold — Session Permanently Dies

**Files:** `lib/core/crypto/noise_session_manager.dart`, lines 252-268; `lib/core/transport/ble_transport.dart`, lines 609-618  
**CVSS Estimate:** 5.0 (Medium)

**Description:**  
When `NoiseSession.shouldRekey` triggers (≥1,000,000 messages), `NoiseSessionManager.encrypt()` disposes the session and returns `null`. The `BleTransport.broadcastPacket()` correctly returns early (CRIT-C2 fix). However:

1. **No code triggers a new Noise handshake** after the session is torn down
2. The peer is effectively **permanently disconnected** from encrypted communication until a BLE reconnection occurs
3. There is **no notification to the application layer** that the session died

The `_initiateNoiseHandshake` method exists (line 884) but is only called once — during initial device discovery (line 517). There is no re-initiation path.

**Impact:** After 1M messages, encrypted communication permanently stops until BLE reconnect.

**Remediation:**
```dart
// In NoiseSessionManager.encrypt():
if (session.shouldRekey) {
  // ... existing teardown ...
  return null; // Let caller trigger re-handshake
}

// In BleTransport.broadcastPacket() and sendPacket():
if (encrypted == null && _noiseSessionManager.hasSession(deviceId) == false) {
  // Session was torn down for rekey — re-initiate handshake
  _initiateNoiseHandshake(deviceId);
  return false;
}
```

---

### 🟡 MEDIUM

---

#### MED-N1: PKCS#7 Padding Oracle Potential in `MessagePadding.unpad()`

**File:** `lib/core/protocol/padding.dart`, lines 21-32  
**CVSS Estimate:** 4.5

**Description:**
```dart
static Uint8List? unpad(Uint8List data) {
  if (data.isEmpty) return null;
  final padLength = data.last;
  if (padLength == 0 || padLength > data.length) return null;
  for (var i = data.length - padLength; i < data.length; i++) {
    if (data[i] != padLength) return null; // ← timing leak
  }
  return Uint8List.sublistView(data, 0, data.length - padLength);
}
```

The padding verification loop returns early on the first mismatch. While `MessagePadding` appears to be defined but **not currently used** in the hot path (the Noise protocol and group cipher handle their own authentication), if it is used in the future with unauthenticated ciphertext, the early-return pattern creates a **padding oracle** that can be exploited to decrypt ciphertext byte-by-byte.

Currently, all encryption in the codebase uses AEAD (authenticated encryption), which prevents this from being exploitable. But the class exists as a utility and could be misused.

**Impact:** Potential future padding oracle if used with unauthenticated encryption.

**Remediation:** Use constant-time comparison and clearly document "must only be used after AEAD verification."

---

#### MED-N2: Handshake Signing Key Payload Not Length-Validated Before Use

**File:** `lib/core/crypto/noise_session_manager.dart`, lines 176-186  
**CVSS Estimate:** 4.3

**Description:**
```dart
// Line 176: readMessage returns decrypted payload
final remoteSigningKey = state.readMessage(messageBytes);

// Line 182: Check length == 32 and non-zero
if (remotePubKey != null && remoteSigningKey.isNotEmpty && remoteSigningKey.length == 32) {
  if (remoteSigningKey.every((b) => b == 0)) {
    throw Exception('Invalid signing key: all-zero key rejected');
  }
```

The validation is correct for the happy path. But the `readMessage` result is the **full decrypted payload** from the Noise handshake message. An attacker who can manipulate the handshake payload (e.g., during their own legitimate handshake with us) could send:
- **0 bytes** — `isNotEmpty` check fails, `peer.signingKey` is never set. The peer gets a session but **no signing key is cached**. This means all future packets from this peer bypass signature verification in `MeshService._onPacketReceived` (because `signingKey` lookup returns `null`).
- **33+ bytes** — `length == 32` check fails, same result: session exists without signing key.

**By deliberately sending a malformed signing key payload, an attacker can establish an encrypted Noise session that bypasses all signature verification.** They can then inject arbitrary packets that the mesh will accept and relay.

**Impact:** Signature verification bypass via intentionally malformed handshake payload.

**Remediation:**
```dart
// Reject the handshake if signing key is invalid — don't establish the session
if (remoteSigningKey.length != 32 || remoteSigningKey.every((b) => b == 0)) {
  state.dispose();
  peer.handshake = null;
  throw Exception('Invalid signing key: rejected');
}
// Only then establish the session:
peer.signingKey = remoteSigningKey;
```

---

#### MED-N3: Group Key Stored as Hex in `GroupStorage` Despite `KeyStorage` Migration to Base64

**File:** `lib/core/identity/group_storage.dart`, lines 32-34, 89-97  
**CVSS Estimate:** 3.8

**Description:**
```dart
// Line 32-34: Group key stored as hex
final keyHex = _toHex(groupKey);
final saltHex = _toHex(salt);
await _storage.write(key: _groupKeyTag, value: keyHex);
```

`KeyStorage` was migrated to base64 encoding (HIGH-C4 fix) to reduce the attack surface of hex-encoded keys in secure storage. However, `GroupStorage` still uses hex encoding for the group key and salt. This inconsistency means:
1. The group key occupies 64 characters in storage (vs 44 for base64)
2. Hex strings pass through Dart's string interning system, creating additional copies in the managed heap
3. The `_toHex` and `_fromHex` methods create intermediate string objects that persist in GC

**Impact:** Increased key material surface area in GC heap; inconsistent encoding strategy.

**Remediation:** Migrate to base64 encoding consistent with `KeyStorage`, with hex fallback for backward compatibility.

---

#### MED-N4: `NoiseSymmetricState._chainingKey` and `._hash` Not Zeroed on Handshake Failure Paths

**File:** `lib/core/crypto/noise_protocol.dart`, lines 241-254, 307-310  
**CVSS Estimate:** 3.5

**Description:**
The `NoiseSymmetricState` zeroes `_chainingKey` and `_hash` during `split()` (line 308-309):
```dart
_chainingKey.fillRange(0, _chainingKey.length, 0);
_hash.fillRange(0, _hash.length, 0);
_cipherState.clear();
```

But on **failure paths** — if a handshake fails mid-way (e.g., `readMessage` throws `NoiseException`), the `NoiseHandshakeState.dispose()` is called (CRIT-4 fix), which zeros the key pairs but **does not call any cleanup on `_symmetricState`**. The `dispose()` method only calls `_symmetricState._cipherState.clear()` (line 555) — `_chainingKey` and `_hash` remain populated with keying material.

**Impact:** Handshake keying material persists in GC heap after failed handshakes.

**Remediation:** Add a `dispose()` method to `NoiseSymmetricState` and call it from `NoiseHandshakeState.dispose()`.

---

#### MED-N5: `_isBase64` Heuristic Can Misclassify Hex Strings as Base64

**File:** `lib/core/crypto/keys.dart`, lines 113-128  
**CVSS Estimate:** 3.0

**Description:**
```dart
bool _isBase64(String s) {
  return s.contains('+') || s.contains('/') || s.contains('=') ||
      (() {
        try {
          base64Decode(s);
          return base64Decode(s).length <= 128;
        } catch (_) {
          return false;
        }
      })();
}
```

The heuristic has edge cases:
1. A 64-character hex string where all characters are in `[0-9a-f]` will be tested by `base64Decode`. Since hex characters are a subset of base64 characters, `base64Decode` may **succeed** on certain hex strings, producing a decoded result that doesn't match the intended key.
2. Example: `"aabbccdd..."` (all lowercase hex) is valid base64 and will decode to different bytes than hex decode.
3. The consequent logic calls `base64Decode(s)` **twice** (line 121 and 123), performing redundant work.

If a hex-encoded key is misidentified as base64 and "migrated", the key bytes will be **corrupted** — the user's identity is silently destroyed.

**Risk Factor:** This would only fire on the first load of a legacy hex key. If `base64Decode` produces 32 bytes (unlikely but possible for certain hex strings), the migration path would corrupt the key.

**Impact:** Potential silent key corruption during legacy migration.

**Remediation:**
```dart
// More robust check: hex strings are always exactly 64 chars for 32-byte keys
// and contain only [0-9a-f]. Base64 for 32 bytes is always 44 chars with '='.
bool _isBase64(String s) {
  // A 32-byte key as hex = 64 chars; as base64 = 44 chars (with padding).
  // A 64-byte key as hex = 128 chars; as base64 = 88 chars.
  // If length is even and all chars are [0-9a-f], it's hex.
  if (s.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) {
    return false; // Definitely hex
  }
  return true; // Assume base64
}
```

---

### 🟢 LOW

---

#### LOW-N1: `FluxonGroup.key` Still Publicly Exposed (Carries over from LOW-C3)

**File:** `lib/core/identity/group_manager.dart`, line 184  
**Status:** Unchanged from v1.

```dart
final Uint8List key; // 32-byte symmetric encryption key — public!
```

**Impact:** Any code with a `FluxonGroup` reference can read the raw group key.

---

#### LOW-N2: File Encryption Key Stored as Hex in `MessageStorageService`

**File:** `lib/core/services/message_storage_service.dart`, lines 52-63  
**CVSS Estimate:** 2.5

**Description:**
```dart
// Line 62: File encryption key stored as hex
final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
await _secureStorage.write(key: _fileKeyStorageKey, value: hex);
```

Same hex encoding issue as MED-N3. The file encryption key should use base64 for consistency.

---

#### LOW-N3: PeerId Hash Code Uses `Object.hashAll` (Non-Collision-Resistant for Set/Map Operations)

**File:** `lib/core/identity/peer_id.dart`, line 16  

```dart
_hashCode = Object.hashAll(bytes);
```

`Object.hashAll` on mobile platforms produces a 32-bit hash with birthday-bound collisions around 65,000 entries. For the `_trustedPeers` `Set<PeerId>` and `FluxonGroup.members`, this causes hash collisions but not actual logic errors (the `==` operator uses `bytesEqual` for correct comparison). Performance degrades with many peers but doesn't affect correctness.

**Impact:** Performance degradation under high peer counts; no security impact.

---

### ℹ️ INFORMATIONAL

---

#### INFO-N1: Emergency Alert Payload Decode Uses `allowMalformed: true`

**File:** `lib/core/protocol/binary_protocol.dart`, line 134

```dart
final message = utf8.decode(data.sublist(19, 19 + msgLen), allowMalformed: true);
```

The chat payload decode correctly uses `allowMalformed: false` (MED-6 fix), but emergency alert payload decode uses `allowMalformed: true`. This allows malformed UTF-8 sequences in emergency messages, which could enable homoglyph attacks or encoding confusion.

---

#### INFO-N2: `_cachedKeyBytes` in `Signatures` Stores Raw Private Key Copy in GC Heap

**File:** `lib/core/crypto/signatures.dart`, line 58

```dart
_cachedKeyBytes = Uint8List.fromList(privateKey);
```

The CRIT-C3 fix introduced constant-time comparison using `_cachedKeyBytes`. However, this stores a **full copy** of the 64-byte Ed25519 private key in the Dart GC heap (separate from the `SecureKey` wrapper). The `clearCache()` method does zero these bytes (lines 72-76), but between `clearCache` calls, the private key exists in both `SecureKey` (mlock'd) and `Uint8List` (GC heap).

**Recommendation:** Use BLAKE2b hash for comparison like `GroupCipher._cachedGroupKeyHash` does.

---

#### INFO-N3: Noise Handshake Keys Are `public` Fields on `NoiseHandshakeState`

**File:** `lib/core/crypto/noise_protocol.dart`, lines 373-378

```dart
Uint8List? localStaticPrivate;       // ← public!
Uint8List? localStaticPublic;        // ← public!
Uint8List? localEphemeralPrivate;    // ← public — this is the forward secrecy key!
Uint8List? localEphemeralPublic;
Uint8List? remoteStaticPublic;
Uint8List? remoteEphemeralPublic;
```

All key material fields are `public`. While Dart doesn't have `private` fields (the `_` convention is library-scope), these are fully accessible by name from any code that holds a `NoiseHandshakeState` reference. If any debug logging or error reporting accidentally includes the handshake state object, ephemeral/static private keys could be leaked.

---

#### INFO-N4: `NoiseSessionManager.clear()` Does Not Dispose Handshake States

**File:** `lib/core/crypto/noise_session_manager.dart`, lines 316-321

```dart
void clear() {
  for (final peer in _peers.values) {
    peer.session?.dispose();
    // ⚠️ peer.handshake?.dispose() is NOT called
  }
  _peers.clear();
}
```

The `clear()` method (called on app shutdown via `BleTransport.stopServices`) disposes sessions but does **not** dispose pending handshake states. Any mid-handshake ephemeral keys will persist in GC heap.

---

## Deep Technical Analysis by Component

### 1. `noise_protocol.dart` — Noise XX Handshake

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **Pattern correctness** | ✅ Correct | XX pattern: e → e,ee,s,es → s,se |
| **DH (X25519)** | ✅ Correct | `sodium.crypto.scalarmult` with immediate zeroing |
| **Cipher** | 🔴 **Wrong variant** | Original ChaCha20 (8-byte nonce) instead of IETF (12-byte) |
| **Hash function** | ✅ Fixed | `_sha256` now uses actual SHA-256 via `pkg_crypto` |
| **HMAC-SHA256** | ✅ Correct | Uses `pkg_crypto.Hmac(pkg_crypto.sha256, key)` |
| **HKDF** | ✅ Correct | RFC 5869 Extract+Expand with proper counter bytes |
| **Replay protection** | ✅ Strong | 1024-bit sliding bitmap with correct bit-shift logic |
| **Nonce management** | ✅ Correct | 32-bit limit enforced with `>=` (catches exactly 0xFFFFFFFF) |
| **State cleanup** | ⚠️ Partial | `_symmetricState._chainingKey` not zeroed on error paths |
| **Split** | ✅ Correct | `_chainingKey` and `_hash` zeroed; cipher state cleared |
| **Extracted nonce** | ✅ Correct | Transport phase uses 4-byte prepended nonce with replay window |
| **Role separation** | ✅ Correct | Initiator uses c1/c2, responder gets c2/c1 |

#### Replay Window Deep-Dive

The sliding window implementation (lines 190-225) was reviewed in detail:

```dart
void _markNonceAsSeen(int receivedNonce) {
  if (receivedNonce > _highestReceivedNonce) {
    final shift = receivedNonce - _highestReceivedNonce;
    // ... shift window right ...
    _replayWindow[0] |= 1; // Mark offset 0
  } else {
    final offset = _highestReceivedNonce - receivedNonce;
    _replayWindow[offset ~/ 8] |= (1 << (offset % 8));
  }
}
```

**Assessment:** The bit-shift logic is correct. When `shift >= replayWindowSize`, the entire window is cleared (line 199). For partial shifts, the high-to-low iteration order (line 204: `j >= 0; j--`) ensures reads always come from unmodified source bytes. The combination of `hiSrc` (byte-level shift) and `bitShift` (sub-byte shift) correctly preserves bits across byte boundaries.

**Edge case verified:** Shift = 0 (duplicate of highest nonce): `_isValidNonce` returns false because `offset = 0` and `_replayWindow[0] & 1 != 0` (bit 0 was set by the previous `_markNonceAsSeen`).

### 2. `keys.dart` — Key Generation & Storage

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **Key generation** | ✅ Correct | Uses `sodium.crypto.box.keyPair()` (CSPRNG-backed) |
| **Storage encoding** | ✅ Fixed | Base64 with hex migration fallback |
| **Migration safety** | ⚠️ Risk | `_isBase64` heuristic can misclassify (MED-N5) |
| **Key lifecycle** | ✅ Correct | `getOrCreate` → `load` → `generate` + `store` pattern |
| **ISP compliance** | ✅ Good | `KeyGenerator` (pure) split from `KeyStorage` (I/O) |
| **Signing key pair** | ✅ Correct | Ed25519 via `sodium.crypto.sign.keyPair()` |

### 3. `signatures.dart` — Ed25519 Signing

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **Algorithm** | ✅ Correct | Ed25519 detached signatures via libsodium |
| **Cache invalidation** | ✅ Fixed | Constant-time XOR comparison of cached key bytes |
| **Cache key storage** | ⚠️ INFO-N2 | Raw private key copy in `_cachedKeyBytes` (GC heap) |
| **Verification** | ✅ Correct | try/catch returns `false` on any error |
| **Cache cleanup** | ✅ Good | `clearCache()` zeros `_cachedKeyBytes` before nulling |

### 4. `group_cipher.dart` — Group Symmetric Encryption

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **Cipher (encrypt)** | ✅ Correct | `sodium.crypto.aead.encrypt` (IETF AEAD) with random nonce |
| **Associated data** | ✅ Fixed | `additionalData` parameter wired through to AEAD |
| **KDF** | ✅ Strong | Argon2id with `opsLimitModerate` / `memLimitModerate` |
| **Group ID** | ✅ Fixed | Derived from Argon2id output, not raw passphrase |
| **Key caching** | ✅ Fixed | Uses BLAKE2b hash for change detection, not raw bytes |
| **Cache cleanup** | ✅ Fixed | `clearCache()` zeros all cached material |
| **Derivation cache** | ✅ Good | BLAKE2b hash of passphrase+salt as cache key (not plaintext) |
| **Base32 codec** | ✅ Correct | RFC 4648 compliant, tested in unit tests |

### 5. `noise_session_manager.dart` — Session Lifecycle

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **LRU eviction** | ✅ Fixed | `handshake?.dispose()` and `session?.dispose()` on eviction |
| **Rate limiting** | ✅ Strong | Per-device (5/min) + global (20/min) |
| **All-zero key check** | ✅ Correct | Rejects all-zero signing keys |
| **Signing key payload** | 🟡 **Risk** | Missing length validation allows bypass (MED-N2) |
| **Rekey mechanism** | 🟠 **Dead** | Session torn down but no re-handshake triggered (HIGH-N4) |
| **`clear()` method** | ⚠️ Incomplete | Doesn't dispose pending handshake states (INFO-N4) |

### 6. `ble_transport.dart` — Wire Protocol Integration

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **Broadcast encrypt** | ✅ Fixed | Returns early when `encrypt()` returns null (CRIT-C2) |
| **`sendPacket` encrypt** | 🔴 **Bug** | Falls through to plaintext when encrypt returns null (CRIT-N2) |
| **Decryption fallback** | ✅ Correct | Returns early on decrypt failure (line 750) |
| **Source ID binding** | ✅ Correct | `sourceId` checked against authenticated peer (CRIT-2) |
| **Signature verification** | ✅ Correct | Ed25519 verify on non-handshake packets (C3) |
| **GATT hardening** | ✅ Good | No read property; write + notify only (MED-2) |
| **Peripheral auth** | ✅ Correct | Only authenticated clients get notifications (CRIT-1) |
| **Rate limiting** | ✅ Strong | Per-device (50ms) + global (100/sec) rate limits |
| **Data size limit** | ✅ Correct | Rejects data > 4096 bytes before parsing (H7) |
| **Handshake timeout** | ✅ Good | 30-second unauthenticated client eviction (MED-7) |
| **MTU handling** | ✅ Good | Disconnects if MTU < 256 (L1) |

### 7. `message_storage_service.dart` — At-Rest Encryption

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| **Cipher** | ✅ Correct | XChaCha20-Poly1305-IETF (correct for file encryption) |
| **Key storage** | ⚠️ Hex | Still uses hex encoding (LOW-N2) |
| **Nonce** | ✅ Correct | Random 192-bit nonce per write (negligible collision risk) |
| **SecureKey caching** | ✅ Fixed | Cached wrapper, disposed in `dispose()` |
| **Migration** | ✅ Good | Graceful plaintext → encrypted migration |
| **File naming** | ✅ Safe | Regex sanitization of groupId for filesystem safety |

---

## Attack Surface Map

```
                         BLE Radio (Passive Sniffing)
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
              │ Advertising │  │ GATT Write│  │GATT Notify│
              │ (UUID only) │  │ (incoming)│  │ (outgoing)│
              └─────┬──────┘  └─────┬─────┘  └─────┬─────┘
                    │               │               │
              Name filter      Rate limit       Auth check
                    │          (50ms/dev)      (CRIT-1 ✅)
                    │               │               │
              ┌─────▼──────────────▼───────────────▼──────────┐
              │                  BLE Transport                  │
              │  ┌──────────────────────────────────────────┐  │
              │  │  Noise Decrypt (if session exists) ✅     │  │
              │  │  Fallback to plaintext ONLY for handshake│  │
              │  │  ⚠️ sendPacket: plaintext fallback bug   │  │
              │  └──────────────────────────────────────────┘  │
              │  ┌──────────────────────────────────────────┐  │
              │  │  Source ID Binding (CRIT-2) ✅            │  │
              │  │  Signature Verification (C3) ✅           │  │
              │  │  ⚠️ Signing key bypass (MED-N2)          │  │
              │  └──────────────────────────────────────────┘  │
              └────────────────────┬───────────────────────────┘
                                   │
              ┌────────────────────▼───────────────────────────┐
              │                  Mesh Service                   │
              │  ┌──────────────────────────────────────────┐  │
              │  │  Signature re-verification ✅              │  │
              │  │  Direct-peer unsigned drop (MED-C6) ✅     │  │
              │  │  ⚠️ Relayed unverified packets accepted   │  │
              │  └──────────────────────────────────────────┘  │
              │  ┌──────────────────────────────────────────┐  │
              │  │  Relay with TTL decrement ✅              │  │
              │  │  Deduplication (packet ID) ✅              │  │
              │  └──────────────────────────────────────────┘  │
              └────────────────────┬───────────────────────────┘
                                   │
              ┌────────────────────▼───────────────────────────┐
              │              Application Layer                  │
              │  ┌────────────────────────────────┐            │
              │  │  Group Encryption (AEAD+AD) ✅  │            │
              │  │  Location/Chat/Emergency        │            │
              │  └────────────────────────────────┘            │
              │  ┌────────────────────────────────┐            │
              │  │  At-Rest Encryption (XChaCha) ✅│            │
              │  └────────────────────────────────┘            │
              └────────────────────────────────────────────────┘
```

---

## Exploit Scenarios

### Scenario 1: Signature Bypass via Malformed Handshake Payload (MED-N2)

**Prerequisites:** Attacker has a Fluxon-capable BLE device within range.

1. Attacker advertises a Fluxon service UUID
2. Victim discovers attacker and initiates Noise handshake (message 1: `e`)
3. Attacker responds with message 2, but uses an **empty payload** (0 bytes) instead of a 32-byte signing key
4. The handshake completes successfully — the Noise channel is established
5. `remoteSigningKey.isEmpty` → `remoteSigningKey.isNotEmpty` check fails → `peer.signingKey` is never set
6. The attacker's session is now established **without a signing key**
7. All packets from the attacker bypass signature verification in `MeshService._onPacketReceived` (line 187: `signingKey == null`, so `verified` stays `false`, but relayed packets are accepted at line 244)
8. Attacker sends forged emergency alerts, chat messages, or location updates with arbitrary `sourceId`

**Severity:** MEDIUM — requires BLE proximity and direct connection. Mitigated by source ID binding (CRIT-2 prevents sourceId spoofing from directly connected peers). But unmitigated for **relay-injected** packets.

### Scenario 2: Plaintext Leak via `sendPacket` Rekey Race (CRIT-N2)

**Prerequisites:** Sustained high-frequency messaging between two peers (~1M messages)

1. Two peers have exchanged >1M messages over a Noise session
2. Peer A calls `sendPacket()` to send a directed message to Peer B
3. `hasSession(deviceId)` returns `true` (session still exists in the map)
4. `encrypt()` detects `shouldRekey`, disposes the session, returns `null`
5. `ciphertext` is `null` → `encodedData` remains the **plaintext** packet bytes
6. `char.write(encodedData)` sends the plaintext over BLE
7. Any passive BLE sniffer within ~100m captures the unencrypted packet

### Scenario 3: TOFU Bypass — Signing Key Substitution (HIGH-N1)

**Prerequisites:** Attacker intercepts BLE communication on first contact

1. Attacker positions themselves between Peer A and Peer B (BLE MiTM, e.g., using Ubertooth)
2. Peer A initiates handshake with Peer B's MAC. Attacker intercepts message 1.
3. Attacker completes the handshake with Peer A using their own static+signing keys
4. Separately, attacker completes a handshake with Peer B using their own keys
5. Peer A and Peer B both believe they're talking to each other
6. Since `IdentityManager.trustPeer()` is never called, there is **no TOFU record** — neither peer will detect the key change

**Note:** The Noise XX pattern provides mutual authentication, so this MiTM is only possible if the attacker can appear as a **different device** to each peer. This is feasible with MAC spoofing but challenging with the rate limiter.

---

## Recommendations & Remediation

### Priority P0 (Fix Before Release)

| ID | Finding | Fix |
|----|---------|-----|
| CRIT-N2 | `sendPacket` plaintext fallback on rekey | Add `return false` when `encrypt()` returns `null` |
| CRIT-N1 | Original ChaCha20 variant | Switch to IETF variant (`sodium.crypto.aead`) |
| MED-N2 | Signing key bypass via empty payload | Reject handshake if signing key is invalid |

### Priority P1 (Fix Soon)

| ID | Finding | Fix |
|----|---------|-----|
| HIGH-N1 | No TOFU for signing keys | Wire up `IdentityManager.trustPeer()` after handshake |
| HIGH-N4 | No re-handshake after rekey | Call `_initiateNoiseHandshake` when encrypt returns null |
| HIGH-N3 | Private keys in GC heap | Store as `SecureKey` instead of `Uint8List` |
| INFO-N4 | `clear()` doesn't dispose handshakes | Add `handshake?.dispose()` in `clear()` loop |

### Priority P2 (Address in Next Sprint)

| ID | Finding | Fix |
|----|---------|-----|
| MED-N1 | PKCS#7 padding oracle | Add constant-time comparison; document AEAD-only usage |
| MED-N3 | Group key stored as hex | Migrate to base64 consistent with `KeyStorage` |
| MED-N4 | SymmetricState not zeroed on error | Add `dispose()` to `NoiseSymmetricState` |
| MED-N5 | `_isBase64` misclassification risk | Use regex-based hex detection |
| INFO-N2 | Cached private key copy | Use BLAKE2b hash for comparison instead |

### Priority P3 (Hardening)

| ID | Finding | Fix |
|----|---------|-----|
| LOW-N1 | Public `FluxonGroup.key` | Make private; expose encrypt/decrypt via methods |
| LOW-N2 | File key stored as hex | Migrate to base64 |
| LOW-N3 | PeerId hash collision | Use first 8 bytes of raw bytes as int hash code |
| INFO-N1 | Emergency UTF-8 malformed | Use `allowMalformed: false` |
| INFO-N3 | Public key fields | Add `@visibleForTesting` annotation |

---

## Positive Security Properties

The codebase demonstrates **excellent** security engineering for a mobile BLE project:

1. ✅ **Noise XX pattern** — mutual authentication, forward secrecy, identity hiding
2. ✅ **Replay protection** — 1024-bit sliding window bitmap with verified bit-shift logic
3. ✅ **Nonce overflow protection** — `>= 0xFFFFFFFF` catches exact overflow
4. ✅ **Handshake rate limiting** — per-device (5/min) + global (20/min)
5. ✅ **Constant-time byte comparison** — XOR accumulator in `bytesEqual`
6. ✅ **Constant-time signing key cache** — XOR comparison for cache invalidation
7. ✅ **All-zero key rejection** — signing keys explicitly checked
8. ✅ **Source ID binding** — authenticated peers cannot spoof source IDs
9. ✅ **GATT hardening** — no read property, write + notify only
10. ✅ **Advertising privacy** — no local name broadcast
11. ✅ **At-rest encryption** — XChaCha20-Poly1305-IETF with per-device key
12. ✅ **No passphrase storage** — only derived keys persisted
13. ✅ **LRU eviction with cleanup** — disposes crypto state on eviction
14. ✅ **Key migration** — backward-compatible hex → base64 migration
15. ✅ **Message type binding** — AEAD associated data prevents cross-type replay
16. ✅ **Handshake timeout** — 30-second timeout for unauthenticated clients
17. ✅ **Stale client eviction** — 60-second timeout for inactive peripheral clients
18. ✅ **HMAC-SHA256 HKDF** — correct RFC 5869 implementation
19. ✅ **Argon2id with moderate params** — strong brute-force resistance for group keys
20. ✅ **Derivation cache keyed by hash** — passphrase never stored as map key

---

## Conclusion

The FluxonApp cryptography layer has seen **substantial improvement** since the v1 audit (78% fix rate). The remaining issues fall into three categories:

1. **Spec compliance** (CRIT-N1): The wrong ChaCha20 variant breaks interoperability and spec proof assumptions — this is the **highest priority fix**.

2. **Integration bugs** (CRIT-N2, MED-N2, HIGH-N4): The crypto primitives are correct, but the integration between `BleTransport`, `NoiseSessionManager`, and `MeshService` has gaps that allow plaintext leaks, signature bypasses, and dead sessions.

3. **Key hygiene** (HIGH-N3, MED-N4, INFO-N2): Private key material lives in unprotected Dart GC heap longer than necessary. This is partially a Dart platform limitation, but wrapping in `SecureKey` wherever possible significantly reduces the exposure window.

**Overall Assessment:** With the P0 fixes applied, this implementation provides **strong security** for a BLE mesh communication system. The Noise XX foundation is solid, and the defense-in-depth layers (rate limiting, source binding, signature verification, AEAD) are well-implemented.
