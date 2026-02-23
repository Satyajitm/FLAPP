# Security Architecture Patterns — Flutter BLE Mesh

## Overview

Security architecture patterns for Flutter mobile apps using BLE mesh networking, dual-layer cryptography (Noise XX + group symmetric), and off-grid peer-to-peer communication. These patterns address the unique challenge of building secure systems without a central server or certificate authority.

## Trust Model

### No Central Authority

FluxonApp operates without servers. This fundamentally changes the trust model:

- **No certificate authority** — peer identity is self-asserted via Ed25519 keypairs
- **No revocation server** — compromised keys cannot be centrally revoked
- **No key escrow** — lost keys mean lost identity, permanently
- **Trust is local** — trust decisions happen on-device via Noise XX mutual authentication

### Trust Boundaries

```
┌─────────────────────────────────────────────┐
│  Trust Boundary 1: On-Device                │
│  ┌──────────────┐  ┌─────────────────────┐  │
│  │ SecureStorage │  │ App Memory (keys,   │  │
│  │ (encrypted)   │  │ sessions, state)    │  │
│  └──────────────┘  └─────────────────────┘  │
├─────────────────────────────────────────────┤
│  Trust Boundary 2: BLE Transport            │
│  ┌──────────────┐  ┌─────────────────────┐  │
│  │ GATT Server   │  │ GATT Client         │  │
│  │ (peripheral)  │  │ (central scanning)  │  │
│  └──────────────┘  └─────────────────────┘  │
├─────────────────────────────────────────────┤
│  Trust Boundary 3: Mesh Network             │
│  ┌──────────────┐  ┌─────────────────────┐  │
│  │ Relay Peers   │  │ Direct Peers        │  │
│  │ (untrusted)   │  │ (Noise-authed)      │  │
│  └──────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────┘
```

**Rule:** Data crossing a trust boundary must be validated, authenticated, or encrypted before use.

## Pattern 1: Defense-in-Depth Packet Processing

### Description

Every received BLE packet passes through multiple security checks before reaching application logic. No single check failure should compromise the system.

### When to Use
- Processing any data received from BLE transport
- Handling relayed packets from untrusted mesh peers
- Deserializing any wire-format data

### Implementation

```dart
// Correct: layered validation
Future<ChatMessage?> processIncomingPacket(Uint8List raw) async {
  // Layer 1: Structure validation (transport layer)
  final packet = FluxonPacket.tryDecode(raw);
  if (packet == null) return null; // malformed

  // Layer 2: Dedup check (mesh layer)
  if (_deduplicator.isDuplicate(packet)) return null;

  // Layer 3: TTL check (mesh layer)
  if (packet.ttl <= 0) return null;

  // Layer 4: Signature verification (crypto layer)
  if (!Signatures.verify(packet, knownSigningKeys)) return null;

  // Layer 5: Group decryption (identity layer)
  final plaintext = _groupCipher.decrypt(packet.payload);
  if (plaintext == null) return null; // wrong group or tampered

  // Layer 6: Application-level validation
  final message = ChatMessage.tryParse(plaintext);
  return message;
}
```

### Anti-Pattern

```dart
// WRONG: skipping layers, trusting deserialized data
void processPacket(Uint8List raw) {
  final packet = FluxonPacket.decode(raw); // throws on malformed — DoS
  final text = utf8.decode(packet.payload); // no decryption!
  _messages.add(ChatMessage(text: text, sender: packet.sourceId));
}
```

## Pattern 2: Secure Key Lifecycle

### Description

Cryptographic keys follow a strict lifecycle: generation → storage → usage → rotation → destruction. Keys never exist in plaintext outside of `flutter_secure_storage` or active memory.

### Key Lifecycle

```
Generate (libsodium RNG)
    ↓
Store (flutter_secure_storage, encrypted by OS keychain)
    ↓
Load (into memory only when needed)
    ↓
Use (Noise XX, Ed25519 signing, group encryption)
    ↓
Rotate (on group membership change, periodic)
    ↓
Destroy (zeroize memory, delete from storage)
```

### Implementation

```dart
class SecureKeyManager {
  final FlutterSecureStorage _storage;

  // Generate with libsodium, store encrypted
  Future<KeyPair> generateAndStore(String label) async {
    final kp = sodium.crypto.box.keyPair(); // X25519
    await _storage.write(
      key: '${label}_secret',
      value: hex.encode(kp.secretKey),
    );
    await _storage.write(
      key: '${label}_public',
      value: hex.encode(kp.publicKey),
    );
    return kp;
  }

  // Load only when needed
  Future<SecureKey?> loadSecretKey(String label) async {
    final hexKey = await _storage.read(key: '${label}_secret');
    if (hexKey == null) return null;
    return SecureKey.fromList(sodium, hex.decode(hexKey));
  }

  // Destroy completely
  Future<void> destroyKey(String label) async {
    await _storage.delete(key: '${label}_secret');
    await _storage.delete(key: '${label}_public');
  }
}
```

### Rules
- Never write keys to `SharedPreferences`, plain files, or logs
- Never hardcode keys or secrets in source code
- Never use `dart:math Random()` for key generation
- Always use `flutter_secure_storage` which delegates to Android Keystore / iOS Keychain

## Pattern 3: BLE Transport Hardening

### Description

BLE is a wireless protocol visible to any nearby device. The transport layer must minimize information leakage and validate all incoming data.

### Advertising Security

```dart
// GOOD: minimal advertising data
void startAdvertising() {
  blePeripheral.startAdvertising(
    AdvertiseData(
      serviceUuids: [fluxonServiceUuid], // only service UUID
      // NO device name, NO manufacturer data with peer info
    ),
  );
}

// BAD: leaking identity in advertising
void startAdvertisingInsecure() {
  blePeripheral.startAdvertising(
    AdvertiseData(
      serviceUuids: [fluxonServiceUuid],
      manufacturerData: {0xFFFF: peerId.bytes}, // peer ID broadcast in clear!
      localName: displayName, // user name visible to everyone!
    ),
  );
}
```

### Input Validation at BLE Boundary

```dart
void onCharacteristicWritten(Uint8List data) {
  // Validate size before any parsing
  if (data.length < FluxonPacket.minHeaderSize) {
    _log.warning('Undersized packet rejected: ${data.length} bytes');
    return;
  }
  if (data.length > TransportConfig.maxPacketSize) {
    _log.warning('Oversized packet rejected: ${data.length} bytes');
    return;
  }

  // Safe to attempt parsing now
  _processPacket(data);
}
```

## Pattern 4: Group Key Derivation

### Description

Group encryption uses a passphrase-derived symmetric key (Argon2id → ChaCha20-Poly1305). The derivation must be deterministic (same passphrase = same key on all devices) but resistant to brute force.

### Secure Derivation

```dart
SecureKey deriveGroupKey(String passphrase, Uint8List salt) {
  return sodium.crypto.pwhash(
    outLen: 32, // 256-bit key
    password: Int8List.fromList(utf8.encode(passphrase)),
    salt: salt, // must be shared with group members
    opsLimit: sodium.crypto.pwhash.opsLimitModerate, // not opsLimitMin!
    memLimit: sodium.crypto.pwhash.memLimitModerate,
  );
}
```

### Rules
- `opsLimit` and `memLimit` must be at least `Moderate` — `Min` is too fast on modern phones
- Salt must be unique per group (derived from group ID, not hardcoded)
- Passphrase minimum length should be enforced in UI (8+ characters)
- Key rotation required when any member leaves the group

## Pattern 5: Noise XX Handshake Security

### Description

The Noise XX handshake provides mutual authentication and forward secrecy for peer-to-peer sessions. Both sides prove identity without pre-shared keys.

### Handshake Flow

```
Initiator                              Responder
    |                                      |
    |-- msg1: e →                          |  (ephemeral key)
    |                                      |
    |              ← msg2: e, ee, s, es ---|  (ephemeral + static + DH)
    |                                      |
    |-- msg3: s, se →                      |  (static + DH, encrypted)
    |                                      |
    |===== session keys derived =====|     |
    |    (encrypt/decrypt channels)        |
```

### Security Properties
- **Forward secrecy**: Compromising long-term keys doesn't reveal past sessions
- **Mutual authentication**: Both sides verify each other's static key
- **Identity hiding**: Static keys transmitted encrypted (msg2 and msg3)
- **Replay protection**: Ephemeral keys ensure unique sessions

### Verification Checklist
- [ ] Ephemeral keys generated fresh per handshake (never reused)
- [ ] Static keys loaded from secure storage (not hardcoded)
- [ ] Handshake state machine rejects out-of-order messages
- [ ] Session keys derived with HKDF after handshake complete
- [ ] Old handshake state cleared after session established
- [ ] Signing keys (Ed25519) distributed in msg2 and msg3 payloads

## Pattern 6: Secure Logging

### Description

Off-grid apps handle sensitive data (keys, peer IDs, GPS coordinates, message content). Logs must never contain PII or cryptographic material.

### Implementation

```dart
// GOOD: SecureLogger usage
class SecureLogger {
  void info(String message) {
    // Allowed: operational info
    debugPrint('[INFO] $message');
  }

  void logPacket(FluxonPacket packet) {
    // Log type and TTL, NOT content or source
    info('Packet: type=${packet.type.name}, ttl=${packet.ttl}');
    // NEVER: info('From: ${packet.sourceId}, payload: ${packet.payload}');
  }

  void logConnection(String deviceId) {
    // Log connection event, truncate device ID
    info('BLE connected: ${deviceId.substring(0, 4)}...');
  }
}
```

### What Must Never Be Logged
- Cryptographic keys (public, private, symmetric, ephemeral)
- Full peer IDs or BLE MAC addresses
- GPS coordinates or location data
- Message content (plaintext or ciphertext)
- Group passphrases or derived keys
- Noise handshake state or session keys

## Pattern 7: Message Storage Security

### Description

Persisted chat messages are stored in per-group JSON files. These files are on the device filesystem and accessible if the device is compromised.

### Current State (MessageStorageService)

Messages are stored as JSON in the app's documents directory. This means:
- Messages are in plaintext on disk
- Protected only by OS-level file permissions
- Accessible via root/jailbreak, ADB backup, or physical device access

### Hardening Options

| Level | Approach | Trade-off |
|---|---|---|
| Current | Plain JSON files | Fast, simple, not encrypted at rest |
| Better | Encrypt JSON with group key before writing | Requires key in memory to read |
| Best | Use SQLCipher or encrypted database | More complex, better query support |

### Rule
Even with plaintext storage, never store cryptographic keys alongside messages. Keys stay in `flutter_secure_storage`; messages can be in files — the threat model accepts that a fully compromised device can read messages, but keys should still require OS keychain extraction.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Trusting BLE MAC Addresses

BLE MAC addresses can be randomized or spoofed. Never use them as identity.

```dart
// WRONG: using BLE address as peer identity
final peerId = bleDevice.remoteId.str; // spoofable!

// RIGHT: using Ed25519 public key hash
final peerId = PeerId.fromPublicKey(verifiedPublicKey); // crypto-bound
```

### Anti-Pattern 2: Decrypt-Then-Validate

```dart
// WRONG: decrypt before checking signature
final plain = groupCipher.decrypt(packet.payload);
if (!signatures.verify(packet)) { /* too late! */ }

// RIGHT: verify signature first, then decrypt
if (!signatures.verify(packet)) return; // reject unsigned
final plain = groupCipher.decrypt(packet.payload);
```

### Anti-Pattern 3: Shared Nonce Counter

```dart
// WRONG: global nonce counter (breaks with concurrent encryption)
static int _nonce = 0;
Uint8List encrypt(Uint8List data) {
  return aead.encrypt(data, nonce: _nonce++); // race condition!
}

// RIGHT: random nonce per operation
Uint8List encrypt(Uint8List data) {
  final nonce = sodium.randombytes.buf(24); // 24-byte random nonce
  return aead.encrypt(data, nonce: nonce);
}
```

### Anti-Pattern 4: Catching Crypto Exceptions Silently

```dart
// WRONG: swallowing crypto failures
try {
  return groupCipher.decrypt(data);
} catch (_) {
  return data; // falls back to plaintext — security bypass!
}

// RIGHT: crypto failure = reject packet
try {
  return groupCipher.decrypt(data);
} catch (e) {
  _log.warning('Decryption failed — rejecting packet');
  return null; // packet dropped
}
```

## Platform-Specific Hardening

### Android

- Set `android:allowBackup="false"` to prevent ADB backup of app data
- Use `NetworkSecurityConfig` to enforce HTTPS for tile fetching
- Set `android:exported="false"` on non-entry activities
- Minimum API level 31+ for BLE permissions model (no location permission needed for BLE on 31+)
- Consider `android:usesCleartextTraffic="false"`

### iOS

- Enable App Transport Security (ATS) — no HTTP exceptions for tile servers
- Use Keychain access groups to isolate FluxonApp keys
- Set `NSFaceIDUsageDescription` if biometric unlock is added
- Background modes: only `bluetooth-central`, `bluetooth-peripheral`, `location`
- No unnecessary entitlements

## Conclusion

Security in an off-grid BLE mesh app is fundamentally different from server-backed apps. There's no central authority to revoke keys, no server to enforce access control, and no network monitoring. Every security decision happens locally on the device. The patterns above prioritize:

1. **Layered defense** — no single point of failure
2. **Minimal trust** — verify everything from BLE transport
3. **Crypto correctness** — use libsodium properly, never roll your own
4. **Minimal exposure** — leak as little as possible in BLE advertising and logs
5. **Graceful rejection** — crypto failures = drop packet, never fall back to insecure
