# 🔐 FluxonApp — Cryptography Layer In-Depth Security Audit

**Date:** 2026-02-25  
**Auditor:** Automated Deep Analysis  
**Scope:** All files under `lib/core/crypto/`, `lib/core/identity/`, and crypto integration points in `lib/core/transport/`, `lib/core/protocol/`, `lib/core/mesh/`, `lib/core/services/`, and `lib/features/`  
**Audit Type:** White-box cryptographic review (full source access)

---

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Findings by Severity](#findings-by-severity)
   - [CRITICAL](#critical-findings)
   - [HIGH](#high-findings)
   - [MEDIUM](#medium-findings)
   - [LOW](#low-findings)
   - [INFORMATIONAL](#informational-findings)
4. [Component-Level Analysis](#component-level-analysis)
5. [Positive Security Properties](#positive-security-properties)
6. [Remediation Summary](#remediation-summary)

---

## Executive Summary

The FluxonApp cryptography layer implements a **Noise XX handshake protocol** (using Curve25519 for DH, ChaCha20-Poly1305 for AEAD, and SHA-256 for hashing) for peer-to-peer encrypted communication, **Ed25519 signatures** for packet authentication, and **Argon2id-derived symmetric encryption** for group-level message confidentiality. Message storage at rest uses XChaCha20-Poly1305 with a per-device key.

Overall, the cryptographic **primitives are well-chosen** and the **Noise protocol implementation follows the spec correctly**. However, several **design-level vulnerabilities** and **integration-layer gaps** exist that could be exploited by a determined attacker with BLE proximity access.

| Severity | Count | Description |
|----------|-------|-------------|
| 🔴 **CRITICAL** | 3 | Exploitable flaws that break confidentiality or authentication guarantees |
| 🟠 **HIGH** | 5 | Significant weaknesses that weaken the security model under realistic attacks |
| 🟡 **MEDIUM** | 6 | Design issues that could be exploited under elevated threat models |
| 🟢 **LOW** | 4 | Minor issues that represent defense-in-depth gaps |
| ℹ️ **INFO** | 3 | Observations and hardening recommendations |

---

## Architecture Overview

```
┌──────────────────────────────────── CRYPTO STACK ─────────────────────────────────────┐
│                                                                                       │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐   │
│  │ KeyGenerator  │   │ Signatures   │   │ GroupCipher   │   │ MessageStorageService│   │
│  │ (Curve25519)  │   │ (Ed25519)    │   │ (AEAD+Argon) │   │ (XChaCha20-Poly1305) │   │
│  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘   └──────────┬───────────┘   │
│         │                  │                   │                      │                │
│  ┌──────▼──────────────────▼───────────────────▼──────────────────────▼───────────┐   │
│  │                         NoiseProtocol (Noise_XX_25519_ChaChaPoly_SHA256)        │   │
│  │  HandshakeState → SymmetricState → CipherState (replay protection, nonce mgmt) │   │
│  └──────┬────────────────────────────────────────────────────────────┬────────────┘   │
│         │                                                            │                │
│  ┌──────▼───────────┐                                      ┌────────▼────────┐       │
│  │ NoiseSession      │                                      │ NoiseSessionMgr  │       │
│  │ (encrypt/decrypt) │◄─────────────────────────────────────│ (per-device)     │       │
│  └──────┬───────────┘                                      └────────┬────────┘       │
│         │                                                            │                │
│  ┌──────▼────────────────────────────────────────────────────────────▼───────────┐    │
│  │                         KeyStorage (FlutterSecureStorage)                      │    │
│  │  Static keys, Signing keys, Group keys, File encryption keys                  │    │
│  └───────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                       │
│  ┌──────────────────────────────────────────────────────────────────────────────┐     │
│  │                  IdentityManager (trust management, TOFU)                    │     │
│  └──────────────────────────────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Findings by Severity

---

### CRITICAL Findings

#### CRIT-C1: ChaCha20-Poly1305 Original Variant Used Instead of IETF Variant — Nonce Collision Risk

**File:** `lib/core/crypto/noise_protocol.dart`, lines 88–118 (NoiseCipherState.encrypt)  
**CVSS Estimate:** 8.1 (High)

**Description:**  
The `NoiseCipherState` uses `sodium.crypto.aeadChaCha20Poly1305` (the **original** DJB construction) which expects an **8-byte nonce**. However, the Noise Protocol Framework spec (`Noise_XX_25519_ChaChaPoly_SHA256`) mandates the **IETF variant** (`ChaCha20-Poly1305-IETF`) with a **12-byte nonce** (RFC 7539).

```dart
// Line 96: 8-byte nonce built for original ChaCha20-Poly1305
_nonceBufferData.setUint64(0, currentNonce, Endian.big);

// Line 99: Uses original variant, NOT IETF
final ciphertext = sodium.crypto.aeadChaCha20Poly1305.encrypt(...)
```

The Noise spec says: *"ChaChaPoly uses ChaCha20-Poly1305 from RFC 7539."* The original variant differs in internal counter layout and nonce size.

**Exploit Scenario:**
- An attacker who captures handshake transcripts cannot mount a standard Noise test-vector validation, because the cipher outputs differ from IETF ChaChaPoly. This means:
  1. **Interoperability is broken** — any other Noise implementation (e.g., a desktop client using libsodium's IETF API) cannot participate in the handshake.
  2. While the original ChaCha20 is still cryptographically secure, the 8-byte nonce reuse window is smaller (2^32 given the 4-byte big-endian counter) and the **internal security proof assumptions differ from the Noise spec's analysis**.

**Impact:** Broken interoperability, deviation from Noise spec's security proof.

**Remediation:**
```dart
// Replace aeadChaCha20Poly1305 with aeadChaCha20Poly1305IETF
// Use 12-byte nonce (4 zero bytes + 4-byte counter per Noise spec)
final _nonceBuffer = Uint8List(12); // IETF nonce is 12 bytes
// Noise spec: nonce = 4 zero bytes || 8-byte big-endian counter
// But since counter is limited to 32 bits: 4 zero || 4 zero || 4-byte BE counter
```

---

#### CRIT-C2: No Re-Keying Mechanism — `shouldRekey` Flag is Dead Code

**File:** `lib/core/crypto/noise_session.dart`, lines 58–59; `lib/core/crypto/noise_session_manager.dart`, lines 256–262  
**CVSS Estimate:** 7.5 (High)

**Description:**  
`NoiseSession.shouldRekey` returns `true` when ≥1,000,000 messages have been sent or received. When triggered, `NoiseSessionManager` tears down the session (`session.dispose()`, `peer.session = null`) and returns `null` from `encrypt()`, expecting the **caller to re-initiate a Noise handshake**.

**However, there is no code anywhere in `BleTransport` or `MeshService` that detects the `null` from `encrypt()` and triggers a re-handshake.** The `sendPacket` and `broadcastPacket` methods silently treat `null` as "no session" and either skip the peer or send data **unencrypted** (in the broadcast path):

```dart
// BleTransport.broadcastPacket, line 648-652:
if (_noiseSessionManager.hasSession(entry.key)) {
  final encrypted = _noiseSessionManager.encrypt(data, entry.key);
  if (encrypted != null) sendData = encrypted;
  // NOTE: hasSession() was true but encrypt() returned null due to rekey
  // → sendData remains the plaintext! Falls through to char.write(sendData)
}
```

Wait — re-reading line 648-652 more carefully: `hasSession()` checks `_peers[deviceId]?.session != null`. After `encrypt()` sets `peer.session = null` (line 261), the next call to `hasSession()` returns `false`. But in the **same iteration** of broadcast, `hasSession()` was already called and returned `true`, so the code enters the block, `encrypt()` tears down the session and returns `null`, and `sendData` remains the **plaintext packet bytes**. The `char.write(sendData)` then sends unencrypted data.

**For the peripheral broadcast path (lines 667-679):** The code correctly handles this by returning early if `encrypted == null`. But the **central broadcast path (lines 648-652) does NOT have this guard.**

**Exploit Scenario:**  
After ~1M messages, the Noise session silently degrades to plaintext for central-role broadcasts. An attacker with sustained BLE proximity could trigger high message volume and then passively sniff unencrypted traffic.

**Impact:** Complete loss of confidentiality for central-role broadcasts after rekey threshold.

**Remediation:**
1. Add the same guard in the central broadcast path:
   ```dart
   if (encrypted != null) {
     sendData = encrypted;
   } else {
     return; // Don't send plaintext — session needs rekey
   }
   ```
2. Implement automatic re-handshake when `encrypt()` returns `null`.
3. Consider implementing Noise IK re-keying instead of full teardown.

---

#### CRIT-C3: Signing Key Cache Invalidation Uses Weak Hash — Collision Allows Key Substitution

**File:** `lib/core/crypto/signatures.dart`, lines 40–44  
**CVSS Estimate:** 6.8 (Medium-High)

**Description:**  
The `Signatures.sign()` method caches the `SecureKey` wrapper for the private key and uses `Object.hashAll(privateKey)` to detect when the key changes:

```dart
final keyHash = Object.hashAll(privateKey);
if (_cachedSigningKey == null || _cachedKeyHashCode != keyHash) {
  _cachedSigningKey?.dispose();
  _cachedSigningKey = SecureKey.fromList(sodium, privateKey);
  _cachedKeyHashCode = keyHash;
}
```

`Object.hashAll` produces a **platform-dependent hash** (typically 32-bit on mobile) which has a **high collision probability**. If two different 64-byte Ed25519 private keys produce the same `Object.hashAll` value (birthday bound: ~65,000 keys for 50% collision probability on 32-bit), the cache returns the **wrong key**, signing messages with a **stale or different identity**.

**Exploit Scenario:**  
In practice, this is unlikely to be actively exploitable since there's typically only one signing key per device. However, in testing or key-rotation scenarios, this could cause:
- Signs with wrong key after identity reset
- `clearCache()` must be called manually but is easy to forget

**Impact:** Signing with wrong key material in edge cases.

**Remediation:**
```dart
// Use constant-time byte comparison instead of weak hash
static Uint8List? _cachedKeyBytes;

if (_cachedSigningKey == null || 
    _cachedKeyBytes == null || 
    !bytesEqual(_cachedKeyBytes!, privateKey)) {
  _cachedSigningKey?.dispose();
  // Store in SecureKey only, not in Dart heap
  _cachedSigningKey = SecureKey.fromList(sodium, privateKey);
  _cachedKeyBytes = Uint8List.fromList(privateKey); // Or use hash with larger output
}
```

---

### HIGH Findings

#### HIGH-C1: Ephemeral Private Key Bytes Remain in Dart GC Heap After Handshake

**File:** `lib/core/crypto/noise_protocol.dart`, lines 506–523  
**CVSS Estimate:** 6.1 (Medium)

**Description:**  
When ephemeral keys are generated in `_generateEphemeralKey()`:
```dart
localEphemeralPrivate = keyPair.secretKey.extractBytes();
localEphemeralPublic = Uint8List.fromList(keyPair.publicKey);
keyPair.secretKey.dispose(); // Zero SecureKey after extracting bytes
```

The `extractBytes()` copies the key into a **regular Dart `Uint8List`** (GC-managed heap memory). While `dispose()` correctly zeros the libsodium `SecureKey`, the **extracted `Uint8List` contents persist in GC heap** until the Dart garbage collector reclaims and overwrites that memory region. The manual zeroing in `dispose()` (lines 529-549) zeros the `Uint8List` fields, but:

1. Dart's GC may have already created **copies** during compaction/generational promotion
2. The original `Uint8List` buffer may be on a different memory page than the one being zeroed
3. The `localEphemeralPrivate` field is a public field, so any code with a reference to the handshake state could have copied it

**Exploit Scenario:**  
On a rooted/jailbroken device, a memory forensics tool could recover ephemeral key material from the Dart heap, enabling retroactive decryption of the session.

**Impact:** Loss of forward secrecy on compromised devices.

**Remediation:**
- Keep ephemeral keys as `SecureKey` (mlock'd memory) rather than extracting to `Uint8List`
- Modify `_performDH` to accept `SecureKey` directly instead of `Uint8List`
- This requires API changes in how scalarmult is called

---

#### HIGH-C2: Group Key Derivation Cache Retains Derived Keys Indefinitely

**File:** `lib/core/identity/group_cipher.dart`, lines 21, 119–153  
**CVSS Estimate:** 5.8 (Medium)

**Description:**  
`GroupCipher._derivationCache` (`Map<String, _DerivedGroup>`) caches Argon2id-derived group keys permanently in Dart heap memory:

```dart
final Map<String, _DerivedGroup> _derivationCache = {};
```

There is no eviction policy, no size limit, and no `dispose()` method. If a user creates/joins multiple groups over time, all previous group keys remain in memory. Additionally, the `_DerivedGroup.key` is a plain `Uint8List` (not a `SecureKey`), so:

1. The 32-byte symmetric group key lives in GC-managed heap
2. Previous group keys from left groups remain accessible via memory forensics
3. No zeroing occurs when leaving a group

**Exploit Scenario:**  
After leaving a group, the group key remains in memory. A memory dump on a rooted device reveals all historical group keys, allowing decryption of previously-captured group traffic.

**Impact:** Past group confidentiality is not guaranteed after leaving.

**Remediation:**
```dart
void clearCache() {
  for (final entry in _derivationCache.values) {
    for (var i = 0; i < entry.key.length; i++) entry.key[i] = 0;
  }
  _derivationCache.clear();
}
```

---

#### HIGH-C3: `bytesEqual` Uses Non-Constant-Time Comparison for Cryptographic Material

**File:** `lib/shared/hex_utils.dart`, lines 7–13  
**CVSS Estimate:** 5.3 (Medium)

**Description:**  
```dart
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;  // ← Early return on first mismatch
  }
  return true;
}
```

This function is used for **peer ID comparison** (`peer_id.dart` line 46), **group key comparison** (`group_cipher.dart` line 51), and **source ID matching** (`mesh_service.dart`). The early-return pattern leaks timing information about where the first byte difference occurs.

**Exploit Scenario:**  
For peer ID comparison, this is lower risk since peer IDs are public. For **group key comparison** in `GroupCipher._getGroupSecureKey()`, an attacker who can trigger many encrypt/decrypt operations with candidate keys could perform a **timing side-channel attack** to recover the group key byte by byte.

In practice, the BLE timing granularity makes this extremely difficult, but it violates cryptographic best practices.

**Impact:** Theoretical side-channel on group key comparison.

**Remediation:**
```dart
bool constantTimeBytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  int result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}
```

---

#### HIGH-C4: Static Private Key Stored as Hex String in FlutterSecureStorage

**File:** `lib/core/crypto/keys.dart`, lines 53–67  
**CVSS Estimate:** 5.5 (Medium)

**Description:**  
The static Curve25519 private key is stored as a hex-encoded string:
```dart
await _storage.write(
  key: _staticPrivateKeyTag,
  value: KeyGenerator.bytesToHex(privateKey),
);
```

On Android, `FlutterSecureStorage` uses the Android Keystore for encryption of the stored values. However:

1. The hex encoding **doubles the key material size** in storage (32 bytes → 64 characters)
2. On some Android versions (pre-API 23), the AES key wrapping may fall back to weaker implementations
3. The hex string passes through Dart's string interning system, potentially creating multiple copies in managed heap
4. When `loadStaticKeyPair()` is called, the hex string is converted back to bytes, creating temporary string objects that persist in GC heap

**Impact:** Increased attack surface for key extraction on older/rooted devices.

**Remediation:**
- Use base64 encoding (smaller, fewer intermediate objects)
- Consider using `FlutterSecureStorage` with `encryptedSharedPreferences` option on Android
- Zero the intermediate hex string after conversion

---

#### HIGH-C5: No Handshake Response Replay Protection

**File:** `lib/core/crypto/noise_session_manager.dart`, lines 138–162  
**CVSS Estimate:** 5.1 (Medium)

**Description:**  
When a responder receives a handshake message 1 (no existing state for the device), it creates a new `NoiseHandshakeState` and processes the message. There is no mechanism to bind the handshake to a specific BLE connection. An attacker who captures the 32-byte ephemeral public key from message 1 could:

1. Replay message 1 from a different BLE device ID
2. The responder creates a new handshake state for the attacker's device ID
3. The attacker completes the handshake using their own static key
4. The responder now has two sessions: one with the legitimate peer and one with the attacker

While the Noise XX pattern prevents the attacker from impersonating the legitimate peer's identity, the responder's connection limit and rate limit can be **exhausted** by replaying captured message 1s from different spoofed MAC addresses.

**Impact:** Handshake resource exhaustion; potential connection slot starvation.

**Remediation:**
- Bind handshake state to BLE connection parameters (e.g., track connection handle)
- The global rate limit (20/minute) partially mitigates this, but MAC address rotation allows bypass

---

### MEDIUM Findings

#### MED-C1: Group Encryption Uses No Associated Data (AD) — Ciphertext Malleability

**File:** `lib/core/identity/group_cipher.dart`, lines 64–83  
**CVSS Estimate:** 4.8

**Description:**  
The group encryption function encrypts with AEAD but passes **no associated data**:
```dart
final ciphertext = sodium.crypto.aead.encrypt(
  message: plaintext,
  nonce: nonce,
  key: _getGroupSecureKey(groupKey),
  // No additionalData parameter!
);
```

While ChaCha20-Poly1305 provides authenticated encryption (the ciphertext itself is authenticated), passing no AD means there is no binding between the ciphertext and its **context** (e.g., the message type, sender identity, or timestamp). An attacker who is a group member could:

1. Capture an encrypted location packet from peer A
2. Re-package it as a chat packet (change the packet header from `0x0A` to `0x02`)
3. The recipient decrypts it with the group key, then tries to parse location binary data as a chat message

The Poly1305 tag only authenticates the **payload**, not the **packet header**.

**Impact:** Cross-type replay within the same group; confused deputy attacks.

**Remediation:**
```dart
// Bind ciphertext to message context
final ad = Uint8List.fromList([messageType, ...sourceId]);
final ciphertext = sodium.crypto.aead.encrypt(
  message: plaintext,
  nonce: nonce,
  key: _getGroupSecureKey(groupKey),
  additionalData: ad,
);
```

---

#### MED-C2: `NoiseSession` Increments `_messagesSent` Before Encryption Succeeds

**File:** `lib/core/crypto/noise_session.dart`, lines 45–48  
**CVSS Estimate:** 4.5

**Description:**  
```dart
Uint8List encrypt(Uint8List plaintext) {
  _messagesSent++;        // ← Incremented BEFORE encryption
  return _sendCipher.encrypt(plaintext);
}
```

If `_sendCipher.encrypt()` throws (e.g., due to `nonceExceeded`), the counter `_messagesSent` is already incremented but no message was actually sent. This causes the rekey threshold check (`shouldRekey`) to be slightly inaccurate. More importantly, if the nonce exceeds `0xFFFFFFFF`, the `NoiseException` propagates but the counter is already bumped. Repeated failed calls would inflate the counter toward the rekey threshold without actual encrypted messages.

**Impact:** Counter desynchronization; premature or delayed rekey.

**Remediation:**
```dart
Uint8List encrypt(Uint8List plaintext) {
  final result = _sendCipher.encrypt(plaintext);
  _messagesSent++;  // Only increment on success
  return result;
}
```

---

#### MED-C3: Group ID Derivation Uses Passphrase in Plaintext as BLAKE2b Input

**File:** `lib/core/identity/group_cipher.dart`, lines 145–149  
**CVSS Estimate:** 4.3

**Description:**  
```dart
final input = Uint8List.fromList(
  utf8.encode('fluxon-group-id:$passphrase:') + salt,
);
final hash = sodium.crypto.genericHash(message: input, outLen: 16);
```

The group ID is derived via BLAKE2b of `fluxon-group-id:<passphrase>:<salt>`. Since the group ID is transmitted in plaintext (as part of group membership), an attacker who captures the group ID and knows the salt (from the join code) can perform an **offline brute-force attack against the passphrase** using only BLAKE2b (not Argon2id).

The Argon2id derivation protects the **group key**, but the **group ID** provides a fast oracle: `BLAKE2b("fluxon-group-id:" + guess + ":" + known_salt) == captured_group_id?`

BLAKE2b is extremely fast compared to Argon2id, so this completely bypasses the Argon2id brute-force resistance for passphrase recovery.

**Impact:** Offline passphrase brute-force via group ID, bypassing Argon2id.

**Remediation:**  
Derive the group ID from the Argon2id output rather than from the raw passphrase:
```dart
// After Argon2id derives keyBytes:
final idInput = Uint8List.fromList(
  utf8.encode('fluxon-group-id:') + keyBytes + salt,
);
final hash = sodium.crypto.genericHash(message: idInput, outLen: 16);
```

---

#### MED-C4: `NoiseSessionManager` Does Not Dispose `NoiseHandshakeState` on LRU Eviction

**File:** `lib/core/crypto/noise_session_manager.dart`, lines 62–75  
**CVSS Estimate:** 4.1

**Description:**  
The `_stateFor` method evicts the oldest peer when the LRU cache exceeds `_maxPeers`:
```dart
while (_peers.length > _maxPeers) {
  _peers.remove(_peers.keys.first);  // Evicted without dispose()
}
```

If the evicted `_PeerState` contains a `handshake` (mid-handshake eviction), the `NoiseHandshakeState.dispose()` is never called. This means ephemeral key material (`localEphemeralPrivate`, etc.) remains in Dart heap memory until garbage collection.

**Impact:** Ephemeral keys from evicted handshakes persist in memory.

**Remediation:**
```dart
while (_peers.length > _maxPeers) {
  final oldestKey = _peers.keys.first;
  final evicted = _peers.remove(oldestKey);
  evicted?.handshake?.dispose();
  evicted?.session?.dispose();
}
```

---

#### MED-C5: `GroupCipher._cachedGroupKeyBytes` Stores Raw Key in GC Heap

**File:** `lib/core/identity/group_cipher.dart`, lines 45–58  
**CVSS Estimate:** 4.0

**Description:**  
```dart
SecureKey _getGroupSecureKey(Uint8List groupKey) {
  // ...
  _cachedGroupKeyBytes = groupKey;  // ← Stores raw key reference in heap
  return key;
}
```

The raw 32-byte group key is stored in `_cachedGroupKeyBytes` as a regular `Uint8List` for comparison purposes. While `_cachedGroupSecureKey` correctly wraps the key in a libsodium `SecureKey` (mlock'd), the comparison copy is in unprotected GC-managed memory.

**Impact:** Group key material exposed in GC heap for memory forensics.

**Remediation:** Use a hash of the key bytes for comparison, not the raw bytes.

---

#### MED-C6: Silent Fallback to Unsigned Packets from Unknown Peers

**File:** `lib/core/mesh/mesh_service.dart`, lines 209–222  
**CVSS Estimate:** 4.5

**Description:**  
When a packet arrives from a peer whose signing key is not yet cached, `MeshService` accepts it **provisionally**:
```dart
SecureLogger.debug(
  'Accepting ${packet.type.name} from unverified peer provisionally',
  category: _cat,
);
```

This creates a **window of vulnerability** between when a peer first connects and when its signing key is learned via the handshake. During this window:
1. Any arbitrary packet (location, emergency) from any source ID is accepted
2. An attacker can inject forged emergency alerts or fake location updates
3. The mesh relay will propagate these unverified packets to other nodes

The BleTransport C4 check (reject unsigned from **direct** authenticated peers) doesn't help for **mesh-relayed** multi-hop packets from peers we haven't directly handshaked with.

**Impact:** Unauthenticated packet injection during bootstrap window and for distant mesh peers.

**Remediation:**
- Cache and verify signing keys distributed via topology announcements
- Drop non-handshake packets from unknown peers by default, with an explicit opt-in for relay mode
- Add a trust-on-first-use (TOFU) mechanism for mesh-relayed signing keys

---

### LOW Findings

#### LOW-C1: `_sha256` in `NoiseSymmetricState` Uses `genericHash` (BLAKE2b), Not SHA-256

**File:** `lib/core/crypto/noise_protocol.dart`, lines 343–346  
**CVSS Estimate:** 3.0

**Description:**  
```dart
Uint8List _sha256(Uint8List data) {
  final sodium = sodiumInstance;
  return sodium.crypto.genericHash(message: data, outLen: 32);
}
```

`sodium.crypto.genericHash` is **BLAKE2b**, not SHA-256. The method is named `_sha256`, and the Noise protocol name string says `SHA256`, but the actual hash function used is BLAKE2b. This is **consistent** with how `_hmacSha256` uses `pkg_crypto.sha256` (actual SHA-256), so:

- `_sha256` (used for `mixHash` and protocol name hashing) → BLAKE2b  
- `_hmacSha256` (used for HKDF) → HMAC-SHA256  

This is a **mismatch**: `mixHash` uses BLAKE2b while HKDF uses SHA-256. The Noise spec requires the **same hash function** for both operations.

**Impact:** Deviation from Noise spec; the handshake transcript hash and key derivation use different hash functions. This doesn't break security (both are strong hash functions), but breaks interoperability with standard Noise implementations and violates the spec's security proof.

**Remediation:**
```dart
Uint8List _sha256(Uint8List data) {
  final digest = pkg_crypto.sha256.convert(data);
  return Uint8List.fromList(digest.bytes);
}
```

---

#### LOW-C2: `KeyGenerator.derivePeerId` Uses BLAKE2b, Not SHA-256 as Documented

**File:** `lib/core/crypto/keys.dart`, lines 27–31  

**Description:**  
```dart
/// Derive a 32-byte peer ID from a public key (SHA-256 hash).
static Uint8List derivePeerId(Uint8List publicKey) {
  final sodium = sodiumInstance;
  return sodium.crypto.genericHash(message: publicKey, outLen: 32);
}
```

The doc comment says "SHA-256 hash" but `genericHash` is BLAKE2b. This is functionally fine but misleading.

**Impact:** Documentation mismatch; no security impact.

---

#### LOW-C3: `FluxonGroup.key` is a Public Final Field of Raw Key Bytes

**File:** `lib/core/identity/group_manager.dart`, lines 167  

**Description:**  
The `FluxonGroup` class exposes the 32-byte symmetric group key as a public final `Uint8List`:
```dart
final Uint8List key;
```

Any code with a reference to a `FluxonGroup` object can read the raw encryption key. While this is needed for the `GroupManager` to encrypt/decrypt, it violates the principle of least privilege.

**Impact:** Increased surface area for accidental key exposure.

**Remediation:** Make `key` private and expose encrypt/decrypt operations through `FluxonGroup` methods.

---

#### LOW-C4: File Encryption Key Created with `SecureKey.fromList` on Every Encrypt/Decrypt Call

**File:** `lib/core/services/message_storage_service.dart`, lines 73–76, 95–98  

**Description:**  
```dart
// Line 76: New SecureKey allocated per encrypt call
key: SecureKey.fromList(sodium, key),
```

Every call to `encryptData()` or `decryptData()` creates a new `SecureKey` from the cached `_fileEncryptionKey` bytes. This:
1. Performs a memory allocation in libsodium's secured heap per call
2. Does not dispose the SecureKey after use (potential leak of mlock'd pages)
3. The underlying `_fileEncryptionKey` in `Uint8List` is already in GC heap

**Impact:** Memory pressure from undisposed SecureKeys; raw key in GC heap.

**Remediation:** Cache the `SecureKey` wrapper and reuse it, similar to `GroupCipher._getGroupSecureKey()`.

---

### INFORMATIONAL Findings

#### INFO-C1: Nonce Counter Type is `int` (64-bit in Dart) vs. 32-bit Protocol Limit

**File:** `lib/core/crypto/noise_protocol.dart`, lines 62, 91

The `_nonce` field is a Dart `int` (64-bit), but the protocol limits it to `0xFFFFFFFF` (32-bit). This is correctly enforced at line 91 (`if (_nonce >= 0xFFFFFFFF)`), so there's no bug. However, ensuring this limit is enforced on both send and receive paths is important — the receive path only enforces it for extracted nonces via `_isValidNonce`, not for sequential nonces.

---

#### INFO-C2: Handshake Response Not Encrypted Through Noise Channel

**File:** `lib/core/transport/ble_transport.dart`, lines 830–848

Handshake response packets are sent as raw (unencrypted) FluxonPackets. This is correct per the Noise protocol (the handshake IS the channel establishment), but it means handshake messages are visible to passive BLE sniffers. The XX pattern provides identity hiding for the static keys (message 2 and 3 encrypt the static key), but ephemeral public keys in message 1 are visible. This is by design.

---

#### INFO-C3: `IdentityManager` Holds Private Keys in Dart Heap for App Lifetime

**File:** `lib/core/identity/identity_manager.dart`, lines 15–18

```dart
Uint8List? _staticPrivateKey;
Uint8List? _signingPrivateKey;
```

These private keys remain in GC-managed heap for the entire app lifetime. On a compromised device, memory dumps can extract these keys. This is a fundamental limitation of Dart (no mlock support for `Uint8List`). Consider keeping these only in `SecureKey` wrappers.

---

## Component-Level Analysis

### 1. `noise_protocol.dart` — Noise XX Handshake Implementation

| Aspect | Assessment |
|--------|-----------|
| **Pattern correctness** | ✅ XX pattern tokens (e, ee, s, es, se) correctly ordered |
| **DH operations** | ✅ X25519 via libsodium scalarmult |
| **Cipher** | ⚠️ Uses original ChaCha20-Poly1305 instead of IETF (CRIT-C1) |
| **Hash function** | ⚠️ `_sha256` actually uses BLAKE2b (LOW-C1), HKDF uses real SHA-256 |
| **HKDF** | ✅ Correct RFC 5869 HMAC-SHA256 implementation |
| **Replay protection** | ✅ 1024-bit sliding window with proper bit-shift logic |
| **Nonce management** | ✅ 32-bit limit enforced, overflow throws |
| **State cleanup** | ⚠️ Ephemeral keys copied to GC heap (HIGH-C1) |
| **Split** | ✅ Chaining key and hash zeroed after transport key derivation |

### 2. `keys.dart` — Key Generation and Storage

| Aspect | Assessment |
|--------|-----------|
| **Key generation** | ✅ Uses libsodium CSPRNG |
| **Storage backend** | ✅ FlutterSecureStorage (Keystore/Keychain) |
| **Key encoding** | ⚠️ Hex encoding creates extra string copies (HIGH-C4) |
| **Key lifecycle** | ✅ Delete methods provided |
| **Separation of concerns** | ✅ KeyGenerator (pure) vs KeyStorage (I/O) split |

### 3. `signatures.dart` — Ed25519 Signing

| Aspect | Assessment |
|--------|-----------|
| **Algorithm** | ✅ Ed25519 detached signatures via libsodium |
| **Caching** | ⚠️ Uses weak `Object.hashAll` for cache invalidation (CRIT-C3) |
| **Verification** | ✅ Wrapped in try/catch, returns false on any error |

### 4. `group_cipher.dart` — Group Symmetric Encryption

| Aspect | Assessment |
|--------|-----------|
| **Cipher** | ✅ AEAD (ChaCha20-Poly1305 via libsodium) |
| **Nonce generation** | ✅ Random nonces per message (no nonce reuse risk) |
| **KDF** | ✅ Argon2id with opsLimitModerate / memLimitModerate |
| **Associated data** | ⚠️ None used (MED-C1) |
| **Key caching** | ⚠️ Raw bytes in GC heap (MED-C5), no eviction (HIGH-C2) |
| **Group ID** | ⚠️ Derived from raw passphrase, not Argon2id output (MED-C3) |

### 5. `noise_session_manager.dart` — Session Lifecycle

| Aspect | Assessment |
|--------|-----------|
| **LRU eviction** | ⚠️ Doesn't dispose evicted handshake states (MED-C4) |
| **Rate limiting** | ✅ Per-device (5/min) + global (20/min) |
| **All-zero key check** | ✅ Rejects all-zero signing keys |
| **Rekey** | ⚠️ Dead code — no re-handshake triggered (CRIT-C2) |

### 6. `message_storage_service.dart` — At-Rest Encryption

| Aspect | Assessment |
|--------|-----------|
| **Cipher** | ✅ XChaCha20-Poly1305-IETF (correct choice for file encryption) |
| **Key storage** | ✅ Per-device key in FlutterSecureStorage |
| **Nonce** | ✅ Random per-write (XChaCha20 192-bit nonce, negligible collision risk) |
| **Migration** | ✅ Graceful legacy plaintext → encrypted migration |
| **SecureKey usage** | ⚠️ Allocates new SecureKey per call, doesn't dispose (LOW-C4) |

---

## Positive Security Properties

The codebase demonstrates several **strong security practices** worth highlighting:

1. ✅ **Noise XX pattern** — provides mutual authentication, forward secrecy, and identity hiding
2. ✅ **Replay protection** — 1024-bit sliding window bitmap with correct shift logic
3. ✅ **Nonce overflow protection** — throws `NoiseError.nonceExceeded` at 2^32
4. ✅ **Handshake rate limiting** — both per-device and global limits prevent DH exhaustion
5. ✅ **Signing key validation** — rejects all-zero signing keys
6. ✅ **Connection limits** — LRU eviction prevents unbounded map growth
7. ✅ **Handshake state disposal** — `CRIT-4` fixes properly zero key material on failure paths
8. ✅ **Post-handshake source binding** — `CRIT-2` prevents source ID spoofing
9. ✅ **Noise session enforcement** — `C4` rejects plaintext from authenticated peers (direct)
10. ✅ **At-rest encryption** — Messages encrypted with per-device key before writing to disk
11. ✅ **No passphrase storage** — Only derived keys are persisted, never raw passphrases
12. ✅ **GATT hardening** — No read property on characteristic; only write + notify

---

## Remediation Summary

| ID | Severity | Finding | Effort | Priority |
|----|----------|---------|--------|----------|
| CRIT-C1 | 🔴 Critical | Wrong ChaCha20 variant (original vs IETF) | Medium | P0 |
| CRIT-C2 | 🔴 Critical | Rekey sends plaintext in central broadcast path | Low | P0 |
| CRIT-C3 | 🔴 Critical | Weak hash for signing key cache invalidation | Low | P0 |
| LOW-C1 | 🟢 Low | `_sha256` uses BLAKE2b (hash function mismatch) | Low | P0* |
| HIGH-C1 | 🟠 High | Ephemeral keys in GC heap | High | P1 |
| HIGH-C2 | 🟠 High | Group key cache never evicted | Low | P1 |
| HIGH-C3 | 🟠 High | Non-constant-time byte comparison | Low | P1 |
| HIGH-C4 | 🟠 High | Private key hex encoding in storage | Medium | P1 |
| HIGH-C5 | 🟠 High | No handshake response replay protection | Medium | P1 |
| MED-C1 | 🟡 Medium | Group encryption has no associated data | Low | P2 |
| MED-C2 | 🟡 Medium | Message counter incremented before success | Low | P2 |
| MED-C3 | 🟡 Medium | Group ID allows fast passphrase brute-force | Low | P2 |
| MED-C4 | 🟡 Medium | LRU eviction doesn't dispose handshake state | Low | P2 |
| MED-C5 | 🟡 Medium | Raw group key in GC heap for comparison | Low | P2 |
| MED-C6 | 🟡 Medium | Silent acceptance of unverified mesh packets | Medium | P2 |
| LOW-C2 | 🟢 Low | Documentation says SHA-256, uses BLAKE2b | Low | P3 |
| LOW-C3 | 🟢 Low | Public `FluxonGroup.key` field | Low | P3 |
| LOW-C4 | 🟢 Low | SecureKey allocated per encrypt call | Low | P3 |

*\*LOW-C1 is marked P0 because it compounds with CRIT-C1 to make the Noise implementation non-compliant with the protocol spec. Fix both together.*

---

## Conclusion

The FluxonApp cryptography layer is **architecturally sound** — the choice of Noise XX, Ed25519, Argon2id, and ChaCha20-Poly1305 represents modern best-practice crypto. The code shows evidence of iterative security hardening (comments referencing CRIT-4, HIGH-3, etc. from prior audits).

The **most urgent fixes** are:
1. **Switch to IETF ChaCha20-Poly1305** and fix the `_sha256`→`BLAKE2b` mismatch (ensures Noise spec compliance)
2. **Guard the central broadcast path** against plaintext fallback on rekey
3. **Add associated data** to group encryption to prevent cross-type replay

With these fixes applied, the cryptography layer would be suitable for a production-grade BLE mesh communication system.
