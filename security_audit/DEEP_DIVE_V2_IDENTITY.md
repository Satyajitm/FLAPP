# 🔍 Deep-Dive Audit: V2 — Identity & Groups

**Date:** 2026-02-25
**Scope:**
- `lib/core/identity/identity_manager.dart`
- `lib/core/identity/group_manager.dart`
- `lib/core/identity/group_cipher.dart`
- `lib/core/identity/group_storage.dart`
- `lib/core/identity/peer_id.dart`
- `lib/core/identity/user_profile_manager.dart`
- `lib/features/group/create_group_screen.dart`
- `lib/features/group/join_group_screen.dart`
- `lib/features/group/share_group_screen.dart`

**Dependencies:** V1 (Crypto — sodium_libs, keys.dart, hex_utils.dart), flutter_secure_storage
**Depended on by:** V4 (Mesh/MeshService), V9 (Chat), V10 (Location), V11 (Emergency), V13 (Group UI)
**Trust boundary:** Validation boundary — manages local identity, group membership, and key material for all encrypted group communications.

---

## Summary

The V2 identity and group subsystem is architecturally sound and shows clear evidence of prior security hardening passes. The passphrase is never stored; only the Argon2id-derived key and salt are persisted. Key derivation uses Argon2id with opsLimitModerate. The group ID is derived from the Argon2id output rather than the raw passphrase, preventing fast brute-force enumeration.

Eight findings were identified: one CRITICAL severity, two HIGH, three MEDIUM, and two LOW. The most significant finding (CRITICAL) is that the QR code in `ShareGroupScreen` embeds the plaintext passphrase in a format (`fluxon:<joinCode>:<passphrase>`) that can be trivially captured from a screenshot, screen recording, or a bystander's camera — negating the confidentiality of the passphrase entirely for the common QR-sharing flow. Secondary concerns include the lack of passphrase upper-bound enforcement at the API layer, Argon2id blocking the UI thread, `unawaited` persistence calls that silently lose errors, and an unbounded trusted-peer set.

---

## Findings

### [CRITICAL] Passphrase Embedded Plaintext in QR Code

**File:** `lib/features/group/share_group_screen.dart`, lines 23, 98
**Lens:** 4 (Security & Cryptography)

**Description:**
`ShareGroupScreen` constructs the QR payload as `'fluxon:${group.joinCode}:$passphrase'` and renders it on-screen via `QrImageView`. The passphrase is the sole secret protecting group membership and all encrypted group traffic.

Embedding it in a QR code means:
1. A screenshot of the share screen captures the passphrase in decodable form.
2. A bystander with a phone camera at any angle can scan the code and silently join the group.
3. The screen is displayed before the creator navigates away, persisting on-screen for an arbitrary duration.
4. Android's recent-apps thumbnail captures the QR code and stores it in the system screenshot cache.

**Exploit/Impact:**
An attacker standing behind a group creator at a festival or disaster-zone triage area can silently scan the QR code from a few metres away, derive the exact same group key, and receive all location updates, chat messages, and emergency alerts for the entire session — without the group being aware. This fully defeats the confidentiality of group communication and location privacy, which are the primary threat model requirements.

**Remediation:**
The join code (which encodes only the salt) can be safely distributed; it is not a secret by itself. The passphrase must be distributed out-of-band (verbal, or a separate secure channel). The QR code should contain only `fluxon:<joinCode>` and the passphrase field should be removed entirely from the QR payload. The `ShareGroupScreen` passphrase parameter should be dropped. The `_parseQrPayload` method in `JoinGroupScreen` should be updated to extract only the join code from a QR scan and require the user to type the passphrase separately.

---

### [HIGH] No Passphrase Upper-Bound Enforced at API Layer

**File:** `lib/core/identity/group_manager.dart`, lines 63, 99; `lib/features/group/create_group_screen.dart`, line 33; `lib/features/group/join_group_screen.dart`, line 50
**Lens:** 1 (Input Validation & Parsing), 8 (Performance & Scalability)

**Description:**
The UI enforces a minimum passphrase length of 8 characters but applies no maximum length. `GroupManager.createGroup()` and `joinGroup()` pass the raw passphrase string directly to `GroupCipher._derive()`, which calls `sodium.crypto.pwhash()` with `passphrase.toCharArray()`. No length cap exists at either the UI or the `GroupManager` API boundary.

A crafted deep-link or malformed QR payload parsed by `_parseQrPayload` can supply a passphrase of arbitrary length (using `parts.sublist(1).join(':')` with no length check) before populating `_passphraseController.text`.

**Exploit/Impact:**
If the user then taps "Join Group", the oversized passphrase bypasses the `length < 8` check and flows directly into Argon2id. On a mid-range Android device, Argon2id at opsLimitModerate already takes 300–500ms; a 1MB passphrase will extend this significantly and cause an ANR (Application Not Responding) timeout since derivation runs synchronously on the main isolate.

**Remediation:**
Add a maximum passphrase length cap (e.g., 128 characters) at the `GroupManager` API level — not just in the UI — so that any caller is protected. Add the same cap to `_parseQrPayload` before setting the text field.

---

### [HIGH] Argon2id Derivation Blocks the UI Thread

**File:** `lib/core/identity/group_manager.dart`, lines 63–91 (`createGroup`), 99–131 (`joinGroup`); `lib/core/identity/group_cipher.dart`, lines 134–173 (`_derive`)
**Lens:** 2 (State Management & Race Conditions), 8 (Performance & Scalability)

**Description:**
`GroupManager.createGroup()` and `joinGroup()` are called directly from the Flutter UI thread via `ref.read(groupManagerProvider).createGroup(...)` and `ref.read(groupManagerProvider).joinGroup(...)`. These methods internally call `GroupCipher._derive()`, which calls `sodium.crypto.pwhash()` — the Argon2id operation — synchronously. At `opsLimitModerate`, Argon2id is intentionally slow (300–500ms).

During this period the Flutter UI is completely frozen — the spinning progress indicator set by `setState(() => _isJoining = true)` will not animate because the UI thread is blocked before the `build` cycle can run.

**Exploit/Impact:**
User-facing ANR or jank. More critically, if the OS kills the process due to an ANR during group creation, `unawaited(_groupStorage.saveGroup(...))` may never complete, leaving the in-memory group state and persistent storage inconsistent.

**Remediation:**
Make `createGroup` and `joinGroup` `async` and run the Argon2id derivation inside `compute()` (Flutter's isolate helper) or `Isolate.run()`. The cache hit path (second call with same inputs) is fast and can remain synchronous.

---

### [MEDIUM] `unawaited` Persistence in `createGroup` and `joinGroup` Silently Loses Errors

**File:** `lib/core/identity/group_manager.dart`, lines 81–89, 120–128
**Lens:** 3 (Error Handling & Recovery), 6 (Data Integrity & Consistency)

**Description:**
Both `createGroup` and `joinGroup` call `unawaited(_groupStorage.saveGroup(...))`. If `flutter_secure_storage` throws (e.g., keystore locked, storage quota exceeded), the exception is silently discarded. The in-memory `_activeGroup` is set, so the group appears active, but no persistent record exists. On the next app launch, `initialize()` returns with `_activeGroup == null`, and the user appears to not be in any group, losing their group membership silently.

**Exploit/Impact:**
Silent data loss. The user is in a group for the current session, sends and receives messages, then restarts the app to find they are no longer in the group and must rejoin. In a disaster-response context where the creator is unreachable, this means permanent loss of group access.

**Remediation:**
Await the `saveGroup` call (making `createGroup` and `joinGroup` `async`) and surface the error to the caller. The UI screens should handle the error and show a snackbar or retry dialog.

---

### [MEDIUM] Unbounded Trusted-Peer Set in IdentityManager

**File:** `lib/core/identity/identity_manager.dart`, lines 24, 74–77, 137–147
**Lens:** 5 (Resource Management & Leaks), 4 (Security & Cryptography)

**Description:**
`_trustedPeers` is a plain `Set<PeerId>` with no size cap. `trustPeer()` adds peers without limit and immediately calls `_persistTrustedPeers()`, which serializes the entire set to JSON and writes it to `flutter_secure_storage`. In a mesh network at a large festival, the device may encounter hundreds of peers over time, causing each new trusted peer to trigger a full set re-serialization and re-encryption write to the keystore.

There is no eviction policy — the set grows monotonically until `resetIdentity()` is called. The JSON blob stored under `trusted_peers_v1` can grow to tens of kilobytes. A very large trusted-peer set could cause the `_persistTrustedPeers` write to fail silently (caught by `catch (_) {}`), leaving in-memory and persistent sets out of sync.

**Exploit/Impact:**
Gradual degradation: over a long session, trust persistence slows and eventually fails silently. An adversary who can generate many ephemeral peer IDs can cause repeated keystore writes (write amplification DoS).

**Remediation:**
Apply an LRU cap (e.g., 500 entries, consistent with `NoiseSessionManager` and `MeshService`) to `_trustedPeers`. Use a `LinkedHashMap`-backed structure and evict the oldest entries when the cap is reached.

---

### [MEDIUM] `decodeSalt` Does Not Validate Decoded Length Against Expected Salt Size

**File:** `lib/core/identity/group_cipher.dart`, lines 238–256
**Lens:** 1 (Input Validation & Parsing)

**Description:**
`decodeSalt(String code)` decodes any base32 string of any length without checking that the result is the expected 16 bytes (`sodium.crypto.pwhash.saltBytes`). A join code shorter than 26 characters decodes to 15 bytes. The `JoinGroupScreen` UI validates `code.length == 26` before calling `joinGroup`, but the API-layer `joinGroup` method accepts any `joinCode` string without enforcing this precondition. Any direct caller (including tests or future programmatic group-join paths) can trigger an out-of-bounds sodium call, which throws a `SodiumException` rather than a clear domain-level error.

**Remediation:**
After decoding, add:

```dart
if (bytes.length != sodium.crypto.pwhash.saltBytes) {
  throw FormatException('Invalid salt length: ${bytes.length}');
}
```

This converts the latent sodium exception into a clear validation error at the correct boundary.

---

### [LOW] Display Name Not Sanitized for Rendering-Level Injection

**File:** `lib/core/identity/user_profile_manager.dart`, lines 26–35
**Lens:** 1 (Input Validation & Parsing), 4 (Security)

**Description:**
`setName` trims whitespace and enforces a 32-character maximum, but does not filter control characters (U+0000–U+001F), Unicode direction-override characters (U+202E RIGHT-TO-LEFT OVERRIDE, U+200F, U+2066–U+2069), or other characters that can alter text rendering in Flutter's `Text` widget. A local user can set their own display name to contain a right-to-left override character, causing their name to render in an unexpected direction and potentially overlap with adjacent UI text.

**Remediation:**
In `setName`, strip or reject characters with Unicode category `Cc`, `Cf`, and `Cs`:

```dart
.replaceAll(RegExp(r'[\x00-\x1F\u200B-\u200F\u202A-\u202E\u2066-\u2069]'), '')
```

---

### [LOW] `trustPeer` and `revokeTrust` Not Awaited at Call Sites — Fire-and-Forget Persistence

**File:** `lib/core/identity/identity_manager.dart`, lines 74–83
**Lens:** 3 (Error Handling & Recovery), 7 (API Contract & Misuse)

**Description:**
`trustPeer(PeerId peerId)` and `revokeTrust(PeerId peerId)` are declared as `Future<void>`. The in-memory mutation is immediate, but `_persistTrustedPeers()` runs asynchronously. A `resetIdentity()` call immediately after a non-awaited `trustPeer` could overwrite storage before the persist completes.

**Remediation:**
Add `@useResult` from `package:meta` or a `@mustBeAwaitedOrIgnored` comment making explicit that unawaited calls are acceptable for the in-memory mutation but persistence may be deferred. Audit production call sites (mesh_service.dart, noise_session_manager.dart handshake completion) to confirm they await or explicitly discard the future.

---

## Cross-Module Boundary Issues

**1. Passphrase Passed as Constructor Argument to ShareGroupScreen**
`CreateGroupScreen._createGroup()` holds the passphrase in a `TextEditingController` and passes it as a named argument to `ShareGroupScreen`. The passphrase string exists in the Flutter widget tree for the lifetime of the `ShareGroupScreen` widget. Flutter may retain the string in memory beyond this point. The passphrase is held as a plain Dart `String` (immutable, GC-managed, not zeroable) with no mechanism to zero it on screen dismissal.

**2. `FluxonGroup.key` Is a Public `Uint8List` Field**
The session memory flags this as an open item. Any consumer with a reference to a `FluxonGroup` instance can read the raw 32-byte group key without going through `GroupCipher`. Any bug in a consuming module (chat, location, emergency) that accidentally logs or serializes the `FluxonGroup` object would expose the key. The key should be package-private, with all encrypt/decrypt operations mediated through `GroupManager`.

**3. `GroupManager` Methods Are Synchronous but Called from Async UI Callbacks**
The `activeGroupProvider` Riverpod `StateProvider` is set immediately after `createGroup`/`joinGroup` returns. If `activeGroupProvider` is read by another provider before the `unawaited` storage write completes and the app is backgrounded, the in-memory group state and persistent state diverge with no way for the Riverpod reactive system to signal this failure.

**4. `initialize()` Trusts Stored Group Key Bytes Without Integrity Check**
`GroupManager.initialize()` loads the stored `groupKey` bytes from `GroupStorage` and uses them directly without any integrity check (no HMAC, no re-derivation). If the keystore entry is corrupted but still passes base64 decoding, the recovered `groupKey` will be silently wrong, causing all subsequent encrypt/decrypt operations to fail — appearing to the user as "wrong group key" rather than "storage corruption."

---

## Test Coverage Gaps

1. **No test for passphrase upper-bound**: No test uses a very long passphrase to verify behavior at or beyond a hypothetical cap. The API currently has no cap to test.
2. **No test for `joinGroup` with a malformed join code**: No test covers `joinGroup` with a code that is not exactly 26 characters or contains invalid base32 characters.
3. **No test for `createGroup`/`joinGroup` storage failure**: No test injects a storage failure to verify that the in-memory group state is still usable and the error is surfaced.
4. **No test for `UserProfileManager` with control/RTL characters**: Tests likely only cover the 32-character truncation and trimming.
5. **No test for concurrent `trustPeer` + `resetIdentity` race**.
6. **`GroupCipher` sodium-dependent paths have no unit test coverage**: All sodium-dependent tests are marked "requires native libs" and substitute a trivially weak XOR placeholder in `FakeGroupCipher`. `deriveGroupKey`, `generateGroupId`, `encrypt`, `decrypt`, `generateSalt`, and `_derive` caching are all exercised only indirectly through the fake, which does not exercise the real Argon2id path.
7. **No test for `GroupStorage._decodeBytes` legacy hex fallback**: `group_storage_test.dart` tests the base64 round-trip but does not write a hex-encoded key and verify the migration path.
8. **No test for `IdentityManager` trusted-peers persistence across simulated app restarts**: No test calls `initialize()`, `trustPeer()`, then constructs a new `IdentityManager` and calls `initialize()` again to verify the trusted set is restored.

---

## Positive Properties

1. **Passphrase never persisted.** `GroupStorage` stores only the Argon2id-derived key and the salt. No code path serializes the passphrase to disk.
2. **Argon2id at opsLimitModerate** with a random 16-byte salt per group, providing meaningful brute-force resistance. Group IDs derived from Argon2id output prevent fast enumeration.
3. **Random salt per group** using `sodium.randombytes.buf(saltBytes)` — CSPRNG. Two groups with the same passphrase are cryptographically independent.
4. **Cache key avoids retaining plaintext passphrase.** `GroupCipher._derive` uses a BLAKE2b-16 hash of `(passphrase || salt)` as the map key, preventing the passphrase from being pinned in a heap-allocated Map entry.
5. **`clearCache` zeros key bytes.** All cached `_DerivedGroup.key` entries are zeroed before clearing the map. The `SecureKey` wrapper is disposed.
6. **`leaveGroup` calls `clearCache`**, ensuring key material is zeroed before the reference is released to the GC.
7. **`GroupStorage` backward-compatible migration.** `_decodeBytes` correctly handles both legacy hex-encoded entries and current base64 entries.
8. **Join code validates format at UI layer.** `JoinGroupScreen._isValidCode` checks both exact length (26) and character set (A-Z, 2-7) before calling `joinGroup`.
9. **`PeerId.fromHex` validates length** and wraps all exceptions in `FormatException`, providing a clear, typed error at the boundary.
10. **`IdentityManager.resetIdentity` zeros private key bytes**, which is correct defensive practice even under GC-managed memory.
11. **`trustedPeers` returns an unmodifiable view**, preventing external callers from mutating the trusted set without going through `trustPeer`/`revokeTrust`.
