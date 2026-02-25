# 🔍 Deep-Dive Audit: V6 — Protocol Layer

**Date:** 2026-02-25
**Scope:**
- `lib/core/protocol/binary_protocol.dart`
- `lib/core/protocol/packet.dart`
- `lib/core/protocol/padding.dart`
- `lib/core/protocol/message_types.dart`

**Dependencies:** Leaf module — imports only `dart:typed_data`, `dart:convert`, `dart:math`, and internal `hex_utils.dart` / `message_types.dart`
**Depended on by:** V3 (`ble_transport.dart`), V4 (`mesh_service.dart`), all feature repositories
**Trust boundary:** Primary validation boundary — all untrusted bytes arriving from the BLE radio are decoded here before being propagated to the rest of the application.

---

## Summary

The protocol layer is in substantially good shape compared to earlier audit cycles. The most dangerous historical vulnerabilities — uncapped `payloadLen` allocation, missing TTL validation, missing timestamp replay window, prefix-only JSON detection, and unbounded neighbor counts — have all been addressed. The constant-time PKCS#7 unpad and `allowMalformed: false` UTF-8 decoding are correctly applied.

Five new findings are raised in this audit: one HIGH, two MEDIUMs, one LOW, and one INFO. None are remotely exploitable in isolation, but two (PROTO-H1 and PROTO-M1) can be chained with upstream BLE delivery to weaken the security guarantees that the rest of the system relies on.

---

## Findings

### [HIGH] Signature Not Committed into the Packet ID — Allows Signature-Swapping Without Dedup Bypass

**File:** `lib/core/protocol/packet.dart`, lines 56–58
**Lens:** 4 (Security & Cryptography), 6 (Data Integrity)

**Description:**
`packetId` is computed as `sourceId:timestamp:type:flags`. The `signature` field is not part of this string. Two packets that are byte-for-byte identical in their header but carry different (or absent) signatures produce exactly the same `packetId`. The deduplicator in `MeshService` and `BleTransport` keys its seen-set on `packetId`.

```dart
String _computePacketId() {
  return '${HexUtils.encode(sourceId)}:$timestamp:${type.value}:$flags';
}
```

**Exploit / Impact:**
Consider a two-step attack:

1. An attacker observes a legitimate signed packet (sourceId=A, timestamp=T, type=chat, flags=F) relayed over the mesh.
2. The attacker immediately replays an identical header with a **stripped or forged signature** to a different node that has not yet seen the packet.
3. Because the `packetId` is identical, the deduplicator on any node that already processed the legitimate version drops the stripped variant — but on a fresh node the stripped variant arrives first and wins.
4. On a fresh node there is a short race window where the unsigned packet can pass through `BleTransport._handleIncomingData` via the `hasSignature: false` fallback path, which fires when `hasSession == false` (pre-handshake nodes). The unsigned packet is then emitted to the app layer.

The window is real: the fallback-to-unsigned path is only gated on `_noiseSessionManager.hasSession(fromDeviceId)`, not on whether a peer-level session has ever been established globally. A fresh cold-boot node with no sessions yet accepts unsigned packets for all types except `handshake`.

The impact is a spoofed message or spoofed emergency alert being delivered before signature verification can fire, on nodes that have not yet established a Noise session with the originating device.

**Remediation:**
Include a boolean `hasSig` flag or the first N bytes of the signature in the `packetId` to discriminate signed from unsigned variants:

```dart
String _computePacketId() {
  final sigPrefix = signature != null
      ? ':${HexUtils.encode(signature!.sublist(0, 8))}'
      : ':nosig';
  return '${HexUtils.encode(sourceId)}:$timestamp:${type.value}:$flags$sigPrefix';
}
```

This ensures that a stripped-signature replay collides only with other stripped-signature copies, not with the legitimate signed version, eliminating the dedup-arbitration race.

---

### [MEDIUM] `sublistView` Aliasing — Decoded Packet Fields Are Mutable External References

**File:** `lib/core/protocol/packet.dart`, lines 140–142, 155, 160
**Lens:** 6 (Data Integrity), 7 (API Contract)

**Description:**
`FluxonPacket.decode()` uses `Uint8List.sublistView` (zero-copy) for `sourceId`, `destId`, `payload`, and `signature`:

```dart
final sourceId = Uint8List.sublistView(data, offset, offset + 32);
final destId   = Uint8List.sublistView(data, offset, offset + 32);
final payload  = Uint8List.sublistView(data, offset, offset + payloadLen);
// ...
signature = Uint8List.sublistView(data, offset, offset + signatureSize);
```

`Uint8List.sublistView` returns a **view** into the original buffer, not a copy. The returned `FluxonPacket` holds aliased references into the buffer that was passed in. If any caller or the BLE layer reuses or modifies that buffer after decode, every derived field in the packet silently changes in place.

In `BleTransport._handleIncomingData` the pattern is `Uint8List.fromList(value)` so the BLE layer does make a copy on the way in — that specific path is safe. However the API contract is not enforced at the decode level: any future caller that passes a slice of a reusable ring buffer (plausible in the gossip or fragment-reassembly paths planned for Phase 5) will silently corrupt all live packet references.

**Exploit / Impact:**
Not currently exploitable given `Uint8List.fromList()` defensive copying in the BLE layer. However this is a latent correctness and security trap. An attacker who can cause a second BLE write to arrive before the first packet is fully processed could theoretically overwrite the buffer backing a packet that is mid-flight through the pipeline.

**Remediation:**
Document the aliasing contract explicitly with a doc comment warning callers not to reuse the source buffer:

```dart
/// IMPORTANT: [data] must not be modified after calling decode(). The returned
/// packet's [sourceId], [destId], [payload], and [signature] fields are
/// zero-copy views into [data]. Callers must ensure the buffer outlives the
/// returned packet.
```

Or add a `copyFields: bool = true` parameter that defaults to defensive copies in production.

---

### [MEDIUM] `encode()` Does Not Validate `payload.length <= maxPayloadSize` — Oversized Payload Encodes Silently

**File:** `lib/core/protocol/packet.dart`, lines 75–98
**Lens:** 1 (Input Validation), 5 (Resource Management)

**Description:**
`FluxonPacket.decode()` correctly rejects packets claiming `payloadLen > 512`. However `FluxonPacket.encode()` and the `FluxonPacket()` constructor apply **no such guard**. Any caller that builds a packet via `FluxonPacket(payload: oversizedBuffer)` can encode and transmit a packet with a payload up to `2^16 - 1 = 65535` bytes (the `payloadLen` field is 16-bit). If `payload.length > 65535`, `setUint16` silently truncates, causing a mismatched length field that the receiver will reject with a bounds-check failure.

**Exploit / Impact:**
A local code-path bug (e.g. an encrypted payload that grows past 512 bytes after AEAD overhead is added) silently produces an oversized packet causing silent message loss. A payload of exactly 65536+ bytes causes `setUint16` to write a truncated length, leading to garbled decode at the remote end.

**Remediation:**
Add a hard runtime guard in `encode()` and `BinaryProtocol.buildPacket`:

```dart
if (payload.length > FluxonPacket.maxPayloadSize) {
  throw ArgumentError('Payload too large: ${payload.length} > ${FluxonPacket.maxPayloadSize}');
}
```

---

### [LOW] `decodeLocationPayload` Does Not Validate Coordinate Ranges — NaN / Infinity Accepted Silently

**File:** `lib/core/protocol/binary_protocol.dart`, lines 92–103
**Lens:** 1 (Input Validation), 4 (Security)

**Description:**
`decodeLocationPayload` reads two `Float64` values for latitude and longitude via `getFloat64`. IEEE 754 `Float64` can represent `NaN`, `+Infinity`, and `-Infinity`. A crafted BLE packet with the appropriate bit patterns passes the `data.length < 32` guard and is decoded into a `LocationPayload` with `latitude = NaN`.

**Exploit / Impact:**
A `NaN` latitude/longitude propagates into `flutter_map` rendering, potentially causing a rendering exception or crashing the location screen. `NaN` comparisons in `GeoMath.haversineDistance` (the 5m throttle) will always return `false`, disabling the throttle for any peer transmitting `NaN` location updates — enabling a bandwidth exhaustion attack.

**Remediation:**
After decoding, validate ranges:

```dart
if (latitude.isNaN || latitude.isInfinite || latitude < -90 || latitude > 90) return null;
if (longitude.isNaN || longitude.isInfinite || longitude < -180 || longitude > 180) return null;
```

Apply similar guards to `accuracy`, `altitude`, `speed`, `bearing`, and to lat/lon in `decodeEmergencyPayload`.

---

### [INFO] `pad()` Accepts `blockSize = 0` — Integer Division by Zero

**File:** `lib/core/protocol/padding.dart`, line 9
**Lens:** 1 (Input Validation), 3 (Error Handling)

**Description:**
`MessagePadding.pad` computes `padLength = blockSize - (data.length % blockSize)`. If `blockSize == 0` is passed, this results in an `IntegerDivisionByZeroException`. No current call site passes `blockSize = 0` (default is 16), but there is no guard.

**Remediation:**
```dart
assert(blockSize > 0, 'blockSize must be positive');
```

---

## Cross-Module Boundary Issues

### Unsigned Packet Fallback Path Is Accessible Pre-Handshake (HIGH — complements PROTO-H1)

**Files:** `lib/core/transport/ble_transport.dart` and `lib/core/protocol/packet.dart`

When `hasSession == false` on a newly connected device, `_handleIncomingData` tries `decode(packetData, hasSignature: true)`, and if that returns `null`, falls through to `decode(packetData, hasSignature: false)`. An unsigned packet from an unauthenticated device will successfully decode on the second attempt and be emitted to the app layer with `signature = null`. The `if (packet.signature != null)` signature-verification block is then skipped entirely, and the packet reaches `_packetController.add(packet)` without any signature check.

This is a complete bypass of Ed25519 verification for packets arriving before handshake completion. The packet is still propagated into the mesh relay pipeline via `MeshService`, potentially being relayed to other nodes.

**Remediation:**
In `_handleIncomingData`, after both decode attempts, if the packet has no signature AND the type is not `handshake`, and no session exists for this device, drop the packet:

```dart
if (packet.signature == null && packet.type != MessageType.handshake) {
  SecureLogger.warning('Unsigned non-handshake packet from unauthenticated peer — dropping', category: 'BLE');
  return;
}
```

### `broadcastPacket` Encodes Packet Header in Plaintext Before Noise Encryption

**Files:** `lib/core/transport/ble_transport.dart`, `lib/core/protocol/packet.dart`

`broadcastPacket` calls `packet.encodeWithSignature()` to get the full wire bytes, then wraps the entire encoded buffer in a Noise `encrypt()` call per peer. This is correct for confidentiality. The BLE advertisement/connection level framing still leaks approximate packet size and timing to BLE observers. This is an accepted residual and is correctly documented in the codebase.

---

## Test Coverage Gaps

1. **No test for `FluxonPacket.decode()` with `payloadLen > maxPayloadSize`** (the 512-byte guard). No test asserts that `payloadLen = 513` or `payloadLen = 65535` returns null.

2. **No test for the timestamp replay window** in `FluxonPacket.decode()`. The ±5 minute check has no test. A test should verify that a packet with `timestamp = now - 6 minutes` is rejected.

3. **No test for `decode()` rejecting `ttl > maxTTL`**. The TTL rejection is untested.

4. **No test for `decodeLocationPayload` with `NaN` / `Infinity` lat-lon**. Directly corresponds to PROTO-L1.

5. **No test for `decodeChatPayload` with a large (>512 byte) `n` or `t` field**. The decoded senderName string is never length-validated before storage and rendering.

6. **No test for `MessagePadding.pad(data, blockSize: 0)`** — the division-by-zero path is completely untested.

7. **No test for `decodeEmergencyPayload` with `latitude = NaN`** or extreme coordinate values.

8. **No test for `encode()` with `payload.length > maxPayloadSize`**. An encode of an oversized payload should either throw or be documented.

9. **No test for `decodeBatchReceiptPayload` with `count = 255`** (maximum `uint8`). The test suite checks `count = 3` but not the max-count edge case.

---

## Positive Properties

1. **`payloadLen > 512` guard is correctly placed before allocation** (packet.dart). The highest-risk historical finding is properly fixed.

2. **`MessageType.fromValue()` returns null for unknown type bytes** and `decode()` correctly rejects `null` type. A packet with type byte `0xFF` is safely dropped.

3. **TTL > maxTTL rejection** prevents relay storms from crafted packets with inflated hop counts.

4. **Timestamp replay window (±5 minutes)** limits the usable window for replayed packets appropriately for a mesh network with potential clock drift.

5. **`decodeChatPayload` strict JSON key validation** uses `containsKey` + type checks rather than a prefix string match, preventing JSON injection via crafted payload content.

6. **`allowMalformed: false`** in both `decodeChatPayload` and `decodeEmergencyPayload` prevents homoglyph and encoding-confusion attacks via malformed UTF-8 byte sequences.

7. **`decodeDiscoveryPayload` neighbor count cap at 10** prevents unbounded allocation from crafted discovery packets.

8. **Constant-time PKCS#7 `unpad()`** uses an XOR accumulator with no early return, correctly avoiding padding oracle side channels.

9. **`MessageType` O(1) lookup map** is built once at class load time, avoiding per-decode linear scans.

10. **`encodeReceiptPayload` sender ID length is implicitly validated** by the `setRange` call, which will throw a `RangeError` if `originalSenderId.length < 32`, providing fail-fast behavior.

11. **`decodeBatchReceiptPayload` count validation** guards against truncated buffers. Since `count` is a `uint8` (0–255), `count * 41` is at most 10455, safely within Dart integer bounds.
