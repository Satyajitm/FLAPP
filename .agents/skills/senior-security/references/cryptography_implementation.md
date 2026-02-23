# Cryptography Implementation — Noise XX, libsodium, Dart

## Overview

FluxonApp uses a dual-layer cryptography architecture built on libsodium (via `sodium_libs` Dart package). This guide covers the correct implementation patterns, common pitfalls, and verification procedures for each crypto primitive used.

## Crypto Stack Summary

| Layer | Algorithm | Purpose | Key Type |
|---|---|---|---|
| Session | Noise XX (X25519 + ChaChaPoly + SHA-256) | Peer-to-peer authenticated encryption | Ephemeral + static Curve25519 |
| Group | ChaCha20-Poly1305 (IETF) | Group message encryption | Argon2id-derived from passphrase |
| Packet Auth | Ed25519 | Packet integrity and origin verification | Ed25519 signing keypair |
| Identity | SHA-256(Ed25519 pubkey) | 32-byte peer ID derivation | Derived from signing key |
| Key Derivation | Argon2id | Passphrase → symmetric group key | Memory-hard KDF output |
| Hashing | BLAKE2b | General-purpose hashing | N/A |

## libsodium in Dart (sodium_libs)

### Initialization

```dart
import 'package:sodium_libs/sodium_libs.dart';

// Global singleton — initialized once in main.dart
late final SodiumSumo sodium;

Future<void> initSodium() async {
  sodium = await SodiumSumoInit.init();
}
```

**Critical:** `SodiumSumoInit.init()` must complete before any crypto operations. It loads the native libsodium library. Call it in `main()` before `runApp()`.

### Why SodiumSumo (not Sodium)?

The `Sumo` variant includes:
- Argon2id (password hashing / KDF) — needed for group key derivation
- Ed25519 ↔ Curve25519 key conversion — needed for Noise XX with Ed25519 identity
- Advanced primitives (BLAKE2b personalization, etc.)

The base `Sodium` package lacks these. Always use `SodiumSumo`.

## Noise XX Protocol

### What is Noise XX?

A two-party authenticated key exchange from the Noise Protocol Framework. "XX" means both parties transmit their static keys during the handshake (neither has prior knowledge of the other).

### Handshake Pattern

```
XX:
  → e                           // Initiator sends ephemeral public key
  ← e, ee, s, es               // Responder: ephemeral, DH(ee), static (encrypted), DH(es)
  → s, se                      // Initiator: static (encrypted), DH(se)
```

After 3 messages, both sides derive:
- A pair of symmetric keys (one per direction) for subsequent encryption
- Verified each other's static public keys

### Implementation Correctness Checklist

#### Ephemeral Key Generation
```dart
// CORRECT: fresh ephemeral keypair per handshake
KeyPair generateEphemeral() {
  return sodium.crypto.box.keyPair(); // X25519
}

// WRONG: reusing ephemeral keys
static final _ephemeral = sodium.crypto.box.keyPair(); // defeats forward secrecy!
```

**Rule:** Ephemeral keys MUST be generated fresh for every handshake. Reusing them destroys forward secrecy — the entire point of the Noise protocol.

#### DH Operations
```dart
// X25519 Diffie-Hellman
Uint8List dh(SecureKey secretKey, Uint8List publicKey) {
  return sodium.crypto.scalarmult(
    x: secretKey,
    groupElement: publicKey,
  );
}
```

**Validation:** The DH result must be checked for all-zeros (low-order point). libsodium's `crypto_scalarmult` does this internally and returns an error.

#### Symmetric Encryption (CipherState)
```dart
// ChaCha20-Poly1305 IETF with incrementing nonce
class CipherState {
  SecureKey key;
  int nonce = 0; // 64-bit counter, big-endian in 96-bit nonce field

  Uint8List encryptWithAd(Uint8List ad, Uint8List plaintext) {
    final nonceBytes = _nonceToBytes(nonce);
    nonce++; // MUST increment after every encryption

    return sodium.crypto.aead.chacha20Poly1305Ietf.encrypt(
      message: plaintext,
      additionalData: ad,
      nonce: nonceBytes,
      key: key,
    );
  }

  Uint8List decryptWithAd(Uint8List ad, Uint8List ciphertext) {
    final nonceBytes = _nonceToBytes(nonce);
    nonce++; // MUST increment after every decryption too

    return sodium.crypto.aead.chacha20Poly1305Ietf.decrypt(
      cipherText: ciphertext,
      additionalData: ad,
      nonce: nonceBytes,
      key: key,
    );
  }

  // 64-bit counter → 96-bit nonce (zero-padded, big-endian)
  Uint8List _nonceToBytes(int n) {
    final bytes = Uint8List(12); // 96-bit
    // Big-endian 64-bit counter in last 8 bytes
    bytes[4] = (n >> 56) & 0xFF;
    bytes[5] = (n >> 48) & 0xFF;
    bytes[6] = (n >> 40) & 0xFF;
    bytes[7] = (n >> 32) & 0xFF;
    bytes[8] = (n >> 24) & 0xFF;
    bytes[9] = (n >> 16) & 0xFF;
    bytes[10] = (n >> 8) & 0xFF;
    bytes[11] = n & 0xFF;
    return bytes;
  }
}
```

**Critical:** In Noise protocol, the nonce is a **counter** (not random). Both sides must increment in lockstep. If messages arrive out of order, the session breaks. This is by design — Noise assumes ordered transport.

#### Hash Function (SHA-256)
```dart
Uint8List hash(Uint8List data) {
  return sodium.crypto.genericHash(
    message: data,
    outLen: 32, // SHA-256 equivalent output length
  );
}
```

**Note:** Noise XX specifies SHA-256, but libsodium's `crypto_generichash` is BLAKE2b. For strict Noise compliance, use `sodium.crypto.shortHash` with SHA-256 or implement SHA-256 separately. Verify which hash function the current implementation uses.

### Session Key Split

After handshake completes:
```dart
// Split symmetric state into two CipherStates
// initiator_key: for initiator → responder
// responder_key: for responder → initiator
(CipherState send, CipherState recv) split() {
  final key1 = hkdf(chainingKey, length: 32, info: Uint8List(0));
  final key2 = hkdf(chainingKey, length: 32, info: Uint8List(1));

  if (isInitiator) {
    return (CipherState(key: key1), CipherState(key: key2));
  } else {
    return (CipherState(key: key2), CipherState(key: key1));
  }
}
```

### Signing Key Distribution

Ed25519 signing keys are distributed as handshake payloads:
- **Message 2 (responder → initiator):** Responder's Ed25519 public key
- **Message 3 (initiator → responder):** Initiator's Ed25519 public key

These payloads are encrypted by the handshake, so signing keys are not visible to eavesdroppers.

## Ed25519 Packet Signing

### Purpose

Every FluxonPacket carries an Ed25519 signature. This provides:
- **Origin authentication** — proves who created the packet
- **Integrity** — detects any modification in transit (including by relay nodes)
- **Non-repudiation** — sender cannot deny having sent the packet

### Signing

```dart
Uint8List signPacket(Uint8List packetBytes, KeyPair signingKey) {
  // Sign everything except the signature field itself
  final dataToSign = packetBytes.sublist(0, packetBytes.length - 64);

  return sodium.crypto.sign.detached(
    message: dataToSign,
    secretKey: signingKey.secretKey,
  );
}
```

### Verification

```dart
bool verifyPacket(FluxonPacket packet, Uint8List signingPublicKey) {
  final dataToVerify = packet.headerAndPayloadBytes; // excludes signature

  return sodium.crypto.sign.verifyDetached(
    signature: packet.signature,
    message: dataToVerify,
    publicKey: signingPublicKey,
  );
}
```

### Pitfalls

1. **Verify before processing** — signature check must happen before decryption or any payload parsing
2. **Correct data scope** — sign/verify the same bytes (header + payload, excluding signature)
3. **Key mapping** — signing key for a peer comes from Noise handshake, not from the packet itself
4. **Don't skip on relay** — relay nodes verify signatures too, not just final recipients

## Group Cipher (ChaCha20-Poly1305 + Argon2id)

### Key Derivation

```dart
SecureKey deriveGroupKey(String passphrase, Uint8List salt) {
  // Argon2id: memory-hard KDF resistant to GPU/ASIC attacks
  return sodium.crypto.pwhash(
    outLen: 32, // 256-bit symmetric key
    password: Int8List.fromList(utf8.encode(passphrase)),
    salt: salt, // 16 bytes, unique per group
    opsLimit: sodium.crypto.pwhash.opsLimitModerate, // 3 iterations
    memLimit: sodium.crypto.pwhash.memLimitModerate,  // 256 MB
  );
}
```

### Argon2id Parameter Guidance

| Parameter | Minimum | Recommended | Maximum (mobile) |
|---|---|---|---|
| opsLimit | Moderate (3) | Moderate (3) | Sensitive (4) |
| memLimit | Moderate (256 MB) | Moderate (256 MB) | Sensitive (1 GB) — may OOM |
| Salt length | 16 bytes | 16 bytes | 16 bytes |
| Output length | 32 bytes | 32 bytes | 32 bytes |

**Warning:** `opsLimitInteractive` (2 iterations) and `memLimitInteractive` (64 MB) are too weak for passphrase-derived keys. Always use at least `Moderate`.

**Mobile constraint:** `memLimitSensitive` (1 GB) may cause OOM on low-RAM devices. Test on target hardware.

### Encryption

```dart
Uint8List encryptGroupMessage(Uint8List plaintext, SecureKey groupKey) {
  // Random nonce — NOT counter-based (unlike Noise CipherState)
  // Random is correct here because group messages are independent
  final nonce = sodium.randombytes.buf(
    sodium.crypto.aead.chacha20Poly1305Ietf.nonceBytes, // 12 bytes
  );

  final ciphertext = sodium.crypto.aead.chacha20Poly1305Ietf.encrypt(
    message: plaintext,
    nonce: nonce,
    key: groupKey,
  );

  // Prepend nonce to ciphertext (receiver needs it)
  return Uint8List.fromList([...nonce, ...ciphertext]);
}
```

**Critical difference from Noise:** Group encryption uses **random nonces** (not counters) because:
- Multiple senders share the same key
- Messages are not ordered
- Counter synchronization across devices is impossible

With random 12-byte nonces, collision probability is negligible up to ~2^48 messages per key.

### Decryption

```dart
Uint8List? decryptGroupMessage(Uint8List data, SecureKey groupKey) {
  if (data.length < 12 + 16) return null; // nonce + minimum AEAD overhead

  final nonce = data.sublist(0, 12);
  final ciphertext = data.sublist(12);

  try {
    return sodium.crypto.aead.chacha20Poly1305Ietf.decrypt(
      cipherText: ciphertext,
      nonce: nonce,
      key: groupKey,
    );
  } on SodiumException {
    return null; // authentication failed — wrong key or tampered
  }
}
```

**Rule:** Decryption failure MUST return null (or equivalent). NEVER fall back to treating ciphertext as plaintext.

## Key Management

### Key Types in FluxonApp

| Key | Algorithm | Storage | Lifecycle |
|---|---|---|---|
| Identity keypair | X25519 (Curve25519) | flutter_secure_storage | Permanent (app lifetime) |
| Signing keypair | Ed25519 | flutter_secure_storage | Permanent (app lifetime) |
| Ephemeral keypair | X25519 | Memory only | Single handshake |
| Noise session keys | ChaCha20-Poly1305 | Memory only | Single session |
| Group symmetric key | ChaCha20-Poly1305 | flutter_secure_storage | Until key rotation |

### Storage Security

```dart
// flutter_secure_storage delegates to:
// - Android: Android Keystore (hardware-backed if available)
// - iOS: Keychain Services (Secure Enclave if available)

const storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
);
```

**Android specifics:**
- `encryptedSharedPreferences: true` — uses AES-256-SIV with Android Keystore master key
- Keys are hardware-backed on devices with TEE/StrongBox
- Not extractable without device unlock

**iOS specifics:**
- `KeychainAccessibility.first_unlock` — available after first unlock since boot
- Backed by Secure Enclave on devices with it
- Not included in unencrypted backups

### Key Rotation

Group keys should be rotated when:
1. A member leaves the group (forward secrecy for the group)
2. Periodically (limit exposure window if key is compromised)
3. On suspicion of compromise

```dart
Future<void> rotateGroupKey(FluxonGroup group, String newPassphrase) async {
  // 1. Derive new key
  final newKey = deriveGroupKey(newPassphrase, group.salt);

  // 2. Broadcast key rotation message (encrypted with OLD key)
  await broadcastKeyRotation(group, newPassphrase);

  // 3. Store new key
  await groupStorage.updateKey(group.id, newKey);

  // 4. Zeroize old key
  oldKey.dispose(); // SecureKey.dispose() zeroizes memory
}
```

## Common Pitfalls

### Pitfall 1: Using dart:math for Crypto

```dart
// CATASTROPHICALLY WRONG
import 'dart:math';
final random = Random();
final key = List.generate(32, (_) => random.nextInt(256));
// dart:math Random is not cryptographically secure!

// CORRECT
final key = sodium.randombytes.buf(32);
// Or for SecureKey:
final key = sodium.crypto.secretBox.keygen();
```

`dart:math Random()` uses a PRNG seeded with low entropy. It's predictable. Always use `sodium.randombytes` or `SecureRandom` from `dart:math` (different class!).

### Pitfall 2: Nonce Reuse

```dart
// WRONG: same nonce for different messages
final fixedNonce = Uint8List(12); // all zeros
encrypt(msg1, nonce: fixedNonce, key: key);
encrypt(msg2, nonce: fixedNonce, key: key); // XOR of plaintexts leaked!

// CORRECT: random nonce per message (for group cipher)
encrypt(msg1, nonce: sodium.randombytes.buf(12), key: key);
encrypt(msg2, nonce: sodium.randombytes.buf(12), key: key);
```

### Pitfall 3: Missing AEAD Tag Verification

```dart
// WRONG: using decrypt without checking authentication
// (libsodium handles this internally — decrypt throws on auth failure)
// But wrapping incorrectly:
try {
  return decrypt(data);
} catch (_) {
  return data; // FALLS BACK TO CIPHERTEXT AS PLAINTEXT!
}

// CORRECT
try {
  return decrypt(data);
} catch (e) {
  return null; // reject
}
```

### Pitfall 4: Timing Side Channels

```dart
// WRONG: byte-by-byte comparison
bool verifyMac(Uint8List expected, Uint8List actual) {
  if (expected.length != actual.length) return false;
  for (int i = 0; i < expected.length; i++) {
    if (expected[i] != actual[i]) return false; // early exit leaks position
  }
  return true;
}

// CORRECT: constant-time comparison (use libsodium)
bool verifyMac(Uint8List expected, Uint8List actual) {
  return sodium.memcmp(expected, actual); // constant-time
}
```

### Pitfall 5: SecureKey Disposal

```dart
// WRONG: letting SecureKey be garbage collected
void processHandshake() {
  final ephemeral = sodium.crypto.box.keyPair();
  final shared = dh(ephemeral.secretKey, remotePubKey);
  // ephemeral.secretKey left in memory until GC!
}

// CORRECT: explicit disposal
void processHandshake() {
  final ephemeral = sodium.crypto.box.keyPair();
  try {
    final shared = dh(ephemeral.secretKey, remotePubKey);
    // use shared...
  } finally {
    ephemeral.secretKey.dispose(); // zeroizes memory
  }
}
```

## Testing Crypto Implementations

### Unit Test Patterns

```dart
// Test: encryption roundtrip
test('group cipher encrypt/decrypt roundtrip', () {
  final key = sodium.crypto.aead.chacha20Poly1305Ietf.keygen();
  final plaintext = utf8.encode('Hello mesh');

  final ciphertext = groupCipher.encrypt(Uint8List.fromList(plaintext), key);
  final decrypted = groupCipher.decrypt(ciphertext, key);

  expect(decrypted, equals(plaintext));
});

// Test: wrong key fails
test('group cipher rejects wrong key', () {
  final key1 = sodium.crypto.aead.chacha20Poly1305Ietf.keygen();
  final key2 = sodium.crypto.aead.chacha20Poly1305Ietf.keygen();
  final plaintext = utf8.encode('Secret');

  final ciphertext = groupCipher.encrypt(Uint8List.fromList(plaintext), key1);
  final result = groupCipher.decrypt(ciphertext, key2);

  expect(result, isNull); // must fail, not return garbage
});

// Test: tampered ciphertext fails
test('group cipher rejects tampered data', () {
  final key = sodium.crypto.aead.chacha20Poly1305Ietf.keygen();
  final ciphertext = groupCipher.encrypt(utf8.encode('Hello'), key);

  // Flip a bit
  ciphertext[ciphertext.length - 1] ^= 0x01;

  final result = groupCipher.decrypt(ciphertext, key);
  expect(result, isNull);
});

// Test: nonce uniqueness
test('encryption produces unique ciphertexts', () {
  final key = sodium.crypto.aead.chacha20Poly1305Ietf.keygen();
  final plaintext = utf8.encode('Same message');

  final ct1 = groupCipher.encrypt(Uint8List.fromList(plaintext), key);
  final ct2 = groupCipher.encrypt(Uint8List.fromList(plaintext), key);

  expect(ct1, isNot(equals(ct2))); // different nonces → different ciphertext
});
```

### Noise XX Test Vectors

Verify against official Noise test vectors from https://noiseprotocol.org/noise.html:

```dart
test('Noise XX handshake matches test vector', () {
  // Use deterministic ephemeral keys from test vector
  final initiatorEphemeral = KeyPair(
    publicKey: hexDecode('...'),
    secretKey: SecureKey.fromList(sodium, hexDecode('...')),
  );
  // ... run handshake with fixed keys
  // ... verify intermediate hashes match test vector
});
```

## Crypto Audit Checklist

### Algorithm Selection
- [ ] X25519 for DH (not ECDH-P256)
- [ ] ChaCha20-Poly1305 IETF for AEAD (not AES-GCM on mobile — no AES-NI)
- [ ] Ed25519 for signatures (not ECDSA)
- [ ] Argon2id for KDF (not PBKDF2 or bcrypt)
- [ ] SHA-256 for Noise hash (verify, not BLAKE2b unless intentional variant)

### Implementation
- [ ] All keys generated with libsodium RNG
- [ ] Ephemeral keys fresh per Noise handshake
- [ ] Nonces never reused (counter for Noise, random for group)
- [ ] Signatures verified before decryption
- [ ] Crypto failures return null/error (never fallback to plaintext)
- [ ] SecureKey.dispose() called when keys are no longer needed
- [ ] No crypto keys in logs, prints, or error messages

### Storage
- [ ] All long-term keys in flutter_secure_storage
- [ ] Android: encryptedSharedPreferences enabled
- [ ] iOS: appropriate KeychainAccessibility level
- [ ] No keys in SharedPreferences or plain files
- [ ] Group passphrases not stored (only derived keys)

### Protocol
- [ ] Noise handshake state machine rejects out-of-order messages
- [ ] Handshake timeout cleans up incomplete state
- [ ] Ed25519 keys distributed in Noise msg2/msg3 payloads
- [ ] Packet signature covers header + payload (not signature itself)
- [ ] Group key rotation broadcasts use old key for encryption
