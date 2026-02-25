# 🔍 Deep-Dive Audit: V11 — Emergency Feature

**Date:** 2026-02-25
**Scope:**
- `lib/features/emergency/emergency_screen.dart`
- `lib/features/emergency/emergency_controller.dart`
- `lib/features/emergency/emergency_providers.dart`
- `lib/features/emergency/data/emergency_repository.dart`
- `lib/features/emergency/data/mesh_emergency_repository.dart`
- `lib/core/protocol/binary_protocol.dart` (emergency encode/decode section)
- `lib/core/mesh/mesh_service.dart` (relay context)
- `test/features/emergency_controller_test.dart`
- `test/features/emergency_screen_test.dart`
- `test/features/emergency_repository_test.dart`

**Dependencies:** V4 (Mesh/MeshService), V2 (Groups/GroupManager, GroupCipher)
**Depended on by:** V15 (App Bootstrap via `emergencyControllerProvider`, `emergencyRepositoryProvider`)
**Trust boundary:** Untrusted zone — processes group-encrypted emergency data from remote peers over BLE mesh; attacker controls packet bytes including sourceId, payload, and timestamp.

---

## Summary

The emergency feature is architecturally sound and applies the correct Clean Architecture layering (Screen → Controller → Repository → Transport). The 3x rebroadcast loop is race-condition-free at the language level because it runs sequentially in a single `async` function, and the `_isDisposed` guard in `retryAlert` correctly handles disposal during the backoff delay. However, five meaningful issues were found. The most significant is that the `alerts` list in `EmergencyState` has no upper bound, meaning a flood of forged or replayed emergency packets from a malicious peer can exhaust heap memory over a long session. A secondary issue is that unknown `alertType` bytes are silently coerced to SOS severity rather than dropped. The `_doSend` catch clause discards the exception without logging it. Cryptographic protection (group key encryption + Ed25519 packet signatures enforced at the mesh layer) is correctly applied before the emergency data reaches this feature.

---

## Findings

### [HIGH] Unbounded `alerts` List — Remote Memory Exhaustion via Alert Flood

**File:** `lib/features/emergency/emergency_controller.dart`, lines 122–124 and 185–200
**Lens:** 8 (Performance & Scalability), 1 (Input Validation)

**Description:**
Every incoming emergency packet appends a new `EmergencyAlert` to `state.alerts`:

```dart
_alertSub = _repository.onAlertReceived.listen((alert) {
  state = state.copyWith(alerts: [...state.alerts, alert]);
});
```

There is no cap. Because `state.alerts` is a Dart `List` that is spread-copied on every mutation, the actual memory cost is O(n²) over the lifetime of the controller. With no deduplication at this layer, a malicious peer can continuously send emergency packets to grow this list without limit.

**Exploit/Impact:**
A BLE-range attacker spoofing distinct `sourceId` bytes per packet can send thousands of emergency packets per minute. In plaintext mode (no group), every valid-looking 19-byte payload is accepted. The resulting heap allocation spiral (O(n²) copy cost) can cause an `OutOfMemoryError` on Android, crashing the app and silencing all emergency UI. Even in group mode, a compromised group member can perform the same attack.

**Remediation:**
Apply the same 200-entry cap pattern already used in `chat_controller.dart`:

```dart
final updated = [...state.alerts, alert];
state = state.copyWith(
  alerts: updated.length > 200
      ? updated.sublist(updated.length - 200)
      : updated,
);
```

Apply the same cap to the local-send path.

---

### [HIGH] No Alert-Type Validation — Unknown `alertType` Silently Defaults to SOS

**File:** `lib/features/emergency/data/mesh_emergency_repository.dart`, line 65
**Lens:** 1 (Input Validation & Parsing)

**Description:**
When decoding an incoming packet, the `alertType` byte is null-coalesced to SOS:

```dart
type: EmergencyAlertType.fromValue(payload.alertType) ?? EmergencyAlertType.sos,
```

Any byte in range 4–255 becomes `EmergencyAlertType.sos`.

**Exploit/Impact:**
A peer running a modified client can set `alertType = 0x05`. All receiving devices display this as an SOS alert (the most urgent type). In a disaster-response scenario, this silently elevates false alerts to SOS severity, diverting responders. A malicious peer can manufacture high-urgency SOS noise with any unknown alertType byte.

**Remediation:**
Reject packets with unrecognized alert types:

```dart
final alertType = EmergencyAlertType.fromValue(payload.alertType);
if (alertType == null) return; // Drop unknown alert types
```

Log the unknown type value via `SecureLogger.warning` for diagnostics.

---

### [MEDIUM] Concurrent `sendAlert` Calls — Interleaved Rebroadcast Loops and `_pendingAlert` Clobber

**File:** `lib/features/emergency/emergency_controller.dart`, lines 131–144; `lib/features/emergency/data/mesh_emergency_repository.dart`, lines 79–117
**Lens:** 2 (State Management & Race Conditions)

**Description:**
`sendAlert` in the controller is `async` but has no guard against concurrent invocation. If the user triggers SOS, then triggers again before the first `_doSend` call completes, two concurrent `_doSend` coroutines execute simultaneously. The second call overwrites `_pendingAlert` before the first call reads it.

**Exploit/Impact:**
The local `EmergencyAlert` appended to state after the first `await _doSend()` resolves will carry the parameters of the second alert. The user sees a confirmation of the wrong alert type (e.g., "Medical" appears in the list but the network received "SOS").

**Remediation:**
Add a sending guard at the start of `sendAlert`:

```dart
if (state.isSending) return; // Drop concurrent sends
```

In `MeshEmergencyRepository.sendAlert`, add a disposed check inside the loop after each `await Future.delayed`.

---

### [MEDIUM] Rebroadcast Loop Reuses Single Encrypted Payload — Fragile Nonce Pattern

**File:** `lib/features/emergency/data/mesh_emergency_repository.dart`, lines 85–116
**Lens:** 4 (Security & Cryptography)

**Description:**
The payload is encrypted once before the `for` loop, and the same ciphertext (same nonce) is broadcast in each rebroadcast iteration. Each call to `buildPacket` generates a new timestamp, so deduplication sees them as distinct. But the encrypted `payload` bytes are identical across all iterations.

**Exploit/Impact:**
If `GroupCipher.encrypt` ever produces a deterministic nonce (e.g., after a key rotation that resets a counter, or after a future refactor), all N rebroadcasts leak the XOR of the keystream, allowing an attacker with multiple captures to recover the plaintext location data from the emergency alert.

**Remediation:**
Move the encryption call inside the loop so each iteration encrypts independently:

```dart
for (var i = 0; i < _config.emergencyRebroadcastCount; i++) {
  var iterPayload = plainPayload; // fresh plaintext copy
  if (_groupManager.isInGroup) {
    final encrypted = _groupManager.encryptForGroup(iterPayload, messageType: MessageType.emergencyAlert);
    if (encrypted != null) iterPayload = encrypted;
  }
  final packet = BinaryProtocol.buildPacket(..., payload: iterPayload, ...);
  await _transport.broadcastPacket(packet);
  ...
}
```

---

### [MEDIUM] Emergency Alert `message` Field Has No Length Cap at Encode Time

**File:** `lib/core/protocol/binary_protocol.dart`, lines 108–123
**Lens:** 1 (Input Validation & Parsing), 8 (Performance & Scalability)

**Description:**
`encodeEmergencyPayload` accepts an unbounded `String message`. The packet-level validation enforces a 512-byte payload cap on receive, but there is no enforcement at the encode call site that `19 + msgBytes.length <= 512`.

**Exploit/Impact:**
A call with a 500-character message would produce a 519-byte payload, either silently truncated/rejected by the packet encoder or broadcast as an oversized packet creating inconsistent mesh behavior.

**Remediation:**
Add message truncation at encode time:

```dart
const _maxMessageBytes = 493; // 512 - 19
final rawBytes = utf8.encode(message);
final msgBytes = rawBytes.length > _maxMessageBytes
    ? rawBytes.sublist(0, _maxMessageBytes)
    : rawBytes;
```

---

### [LOW] `_doSend` Catch Block Silently Discards Exception

**File:** `lib/features/emergency/emergency_controller.dart`, lines 201–203
**Lens:** 3 (Error Handling & Recovery)

**Description:**
```dart
} catch (_) {
  if (_isDisposed) return;
  state = state.copyWith(isSending: false, hasSendError: true);
}
```

Unlike other controllers in the codebase that use `SecureLogger.warning(...)`, this catch path produces no diagnostic output.

**Remediation:**
```dart
} catch (e) {
  SecureLogger.warning('EmergencyController: sendAlert failed: $e');
  if (_isDisposed) return;
  state = state.copyWith(isSending: false, hasSendError: true);
}
```

---

### [LOW] Alert-Type Chips on Screen Are Non-Functional

**File:** `lib/features/emergency/emergency_screen.dart`, lines 139–162
**Lens:** 7 (API Contract & Misuse)

**Description:**
The three alert-type chips (Medical, Lost, Danger) rendered by `_buildAlertTypeGrid` have no `onTap` handler. They are purely decorative `Column` widgets. The only way to trigger an alert from the UI is the SOS button which hard-codes `EmergencyAlertType.sos`.

**Exploit/Impact:**
No security impact. A user in a genuine medical emergency who sees "Medical" and taps it will get no response.

**Remediation:**
Either wire up `GestureDetector.onTap: () => _sendSos(EmergencyAlertType.medical)` on the chip, or add a doc comment making explicit that the chips are informational labels for received alerts only.

---

### [LOW] `emergencyRepositoryProvider` and `EmergencyController.dispose()` Both Call `repository.dispose()` — Double Dispose Risk

**File:** `lib/features/emergency/emergency_providers.dart`, lines 13–26; `lib/features/emergency/emergency_controller.dart`, lines 207–213
**Lens:** 5 (Resource Management & Leaks)

**Description:**
Both `emergencyRepositoryProvider.onDispose` and `EmergencyController.dispose()` call `_repository.dispose()`. Riverpod disposes `emergencyControllerProvider` first (which calls `controller.dispose()` → `repository.dispose()`), then `emergencyRepositoryProvider` (which calls `repository.dispose()` again). Calling `_alertController.close()` on an already-closed `StreamController` throws a `StateError`.

**Remediation:**
Add a `_disposed` guard to `MeshEmergencyRepository.dispose()`:

```dart
bool _disposed = false;

@override
void dispose() {
  if (_disposed) return;
  _disposed = true;
  _packetSub?.cancel();
  _alertController.close();
}
```

---

### [INFO] `EmergencyAlert.timestamp` Uses Receive-Time as Default

**File:** `lib/features/emergency/emergency_controller.dart`, lines 70–78
**Lens:** 6 (Data Integrity & Consistency)

**Description:**
For locally-sent alerts, `EmergencyAlert` defaults `timestamp` to `DateTime.now()` at construction time, which is consistent and correct. However, the constructor allows `timestamp` to be `null` with `DateTime.now()` as default, meaning if a future caller omits the timestamp for a remote alert, the alert gets receive-time rather than send-time.

**Remediation:**
Make `timestamp` required in `EmergencyAlert` to force all callsites to be explicit.

---

## Cross-Module Boundary Issues

**1. Emergency packets have no priority lane in MeshService.**
Emergency alerts travel through `MeshService` using the same flood-relay path as chat and location packets. In a congested mesh, emergency packets can be queued behind chat packets and subject to the same TTL-based drop logic. There is no priority relay for emergency traffic.

**2. Symmetric AEAD additional data (AD) tag is correct.**
Both `encryptForGroup` and `decryptFromGroup` pass `messageType: MessageType.emergencyAlert` as the AEAD additional data. This prevents ciphertext reuse across message types — a positive finding.

**3. `MeshEmergencyRepository` constructor accepts `GroupManager? groupManager` with a fallback to `GroupManager()`.**
A default-constructed `GroupManager()` has no cipher injected and will return `isInGroup = false`, causing all packets to be sent and received in plaintext. The provider always injects the real `groupManager` in production, but the silent encryption-disable is dangerous if a future test or integration scenario relies on this default.

---

## Test Coverage Gaps

1. **No test for concurrent `sendAlert` scenario.** The test suite has no test calling `sendAlert` twice without awaiting the first.
2. **No test for the unbounded `alerts` list.** No test sends more than a handful of alerts and verifies a cap.
3. **No test for unknown `alertType` byte in the receive path.** The silent coercion to SOS has no test either asserting or rejecting it.
4. **No test for the double-dispose scenario.** No test creates and disposes both controller and repository in Riverpod teardown order.
5. **No test for rebroadcast-during-dispose.** No test calls `repository.dispose()` while `sendAlert` is mid-loop.
6. **`emergency_screen_test.dart` does not test alert-type chip tap behavior.** If chips become interactive, a regression could go undetected.
7. **No test for `encodeEmergencyPayload` with a message exceeding 493 bytes.**

---

## Positive Properties

1. **Correct group-encryption boundary.** `_handleIncomingAlert` returns early when `decryptFromGroup` returns null, preventing cross-group emergency spoofing.
2. **Correct `MessageType` additional data in AEAD.** Prevents ciphertext reuse across message types.
3. **Exponential backoff with `_isDisposed` guard.** The retry logic correctly backs off and checks disposal state after each `await Future.delayed`.
4. **Long-press confirmation UX.** Two-step interaction prevents accidental SOS triggers.
5. **`Random.secure()` used for jitter.** Prevents timing-analysis fingerprinting of the sender's BLE transmission pattern.
6. **`allowMalformed: false` in UTF-8 decode.** Correctly rejects malformed UTF-8 in the message field.
7. **Clean repository dispose pattern.** `_packetSub?.cancel()` and `_alertController.close()` are both called (modulo the double-dispose issue).
8. **`EmergencyAlertType._byValue` O(1) lookup.** Enum uses a compile-time-built Map for `fromValue` lookups.
9. **Separation of concerns.** Repository owns encoding, encryption, and transport. Controller owns state transitions and retry logic. Screen owns only presentation and user input.
