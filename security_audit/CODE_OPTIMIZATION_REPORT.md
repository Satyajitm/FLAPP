# FluxonApp — Code Optimization Report

> **Generated**: 2026-02-24  
> **Scope**: All 66 Dart source files across `lib/core/`, `lib/features/`, and `lib/shared/`

---

## Table of Contents
1. [🔴 Critical / High-Impact Optimizations](#1--critical--high-impact-optimizations)
2. [🟠 Medium-Impact Optimizations](#2--medium-impact-optimizations)
3. [🟡 Low-Impact / Code-Quality Improvements](#3--low-impact--code-quality-improvements)
4. [Summary & Prioritized Action Items](#4--summary--prioritized-action-items)

---

## 1. 🔴 Critical / High-Impact Optimizations

### 1.1 — Duplicate `_bytesEqual()` helper (3 copies)

**Files:**
- `lib/core/mesh/mesh_service.dart` (line 368)
- `lib/core/identity/peer_id.dart` (line 49)
- `lib/core/transport/transport.dart` → `PeerConnection.peerIdHex` uses inline per-byte `.map()`

**Problem:** Three independent byte-comparison implementations. The one in `PeerConnection.peerIdHex` (line 19–20 of `transport.dart`) also uses `b.toRadixString(16).padLeft(2,'0')` per-call, allocating a new String every time.

**Fix:** Extract a single canonical `_bytesEqual` into `hex_utils.dart` (or a new `byte_utils.dart`). Use the pre-computed `_hexTable` from `keys.dart` for hex encoding in `PeerConnection.peerIdHex` as well.

**Impact:** Eliminates code duplication + removes repeated String allocations on every peer-connection event.

---

### 1.2 — Duplicate hex encoding implementations (4 copies)

**Files:**
- `lib/shared/hex_utils.dart` → `HexUtils.encode()` — uses `.map(b => b.toRadixString(16)...)`
- `lib/core/crypto/keys.dart` → `KeyGenerator.bytesToHex()` — uses a pre-computed `_hexTable`
- `lib/core/transport/transport.dart` → `PeerConnection.peerIdHex` — inline `.map()`
- `lib/core/protocol/packet.dart` → `FluxonPacket.packetId` (line 47) — inline `.map()`

**Problem:** `HexUtils.encode` is the most-called hex encoder in the app (used in mesh_service, topology_tracker, receipt_service, peer_id, etc.) but it allocates an intermediate `Iterable<String>` on every call. `KeyGenerator.bytesToHex` is faster (lookup table) but is never reused elsewhere.

**Fix:** Migrate `HexUtils.encode()` to use the pre-computed `_hexTable` from `keys.dart`, and make all other call sites delegate to `HexUtils.encode()`.

```dart
// shared/hex_utils.dart — optimized
class HexUtils {
  static final _hexTable = List.generate(256,
    (i) => i.toRadixString(16).padLeft(2, '0'), growable: false);

  static String encode(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) buf.write(_hexTable[b]);
    return buf.toString();
  }
  // ...
}
```

**Impact:** Hot path — called on every packet receive/send for signature verification, deduplication, and topology. Benchmark estimate: **~3–5× faster** hex encoding.

---

### 1.3 — `PeerId.hashCode` uses `Object.hashAll(bytes)` on 32 bytes every time

**File:** `lib/core/identity/peer_id.dart` (line 44)

**Problem:** `PeerId` is used as a `Map` key and `Set` element throughout the app (member locations, delivered-to sets, read-by sets). `Object.hashAll(bytes)` iterates all 32 bytes on every `hashCode` call. Since `PeerId` is immutable, the hash should be computed once and cached.

**Fix:**
```dart
class PeerId {
  final Uint8List bytes;
  late final int _hash = Object.hashAll(bytes);

  @override
  int get hashCode => _hash;
}
```

**Impact:** Every `Map`/`Set` lookup, insertion, and comparison involving `PeerId` becomes O(1) for hash computation instead of O(32).

---

### 1.4 — `FluxonPacket.packetId` is recomputed on every access

**File:** `lib/core/protocol/packet.dart` (line 46–48)

**Problem:** `packetId` is a **computed getter** that allocates a new hex string from the 32-byte `sourceId` every time it's accessed. It's called:
- In `MessageDeduplicator.isDuplicate()` — every incoming packet
- In `GossipSyncManager.onPacketSeen()` — every incoming packet
- In `MeshChatRepository` — to map message IDs
- In `ChatController._handleReceipt` — for receipt matching

**Fix:** Cache the packet ID string:
```dart
late final String packetId = () {
  final src = sourceId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$src:$timestamp:${type.value}';
}();
```
Or better: use `HexUtils.encode(sourceId)` after applying fix 1.2.

**Impact:** Eliminates repeated 32-byte hex encoding on every packet. Estimate: **100–500 μs saved per packet** depending on device.

---

### 1.5 — `GossipSyncManager._packetOrder` uses `removeAt(0)` on a `List`

**File:** `lib/core/mesh/gossip_sync.dart` (line 56)

**Problem:** `_packetOrder.removeAt(0)` is O(n) on a Dart `List` (array copy). Called in the tight loop `while (_packetOrder.length > config.seenCapacity)`.

**Fix:** Use a `Queue<String>` instead:
```dart
final Queue<String> _packetOrder = Queue();
// ...
while (_packetOrder.length > config.seenCapacity) {
  final victim = _packetOrder.removeFirst(); // O(1)
  _seenPackets.remove(victim);
}
```

**Impact:** Fixes a potential O(n²) bottleneck under high packet load.

---

### 1.6 — `Signatures.sign()` allocates a new `SecureKey` on every call

**File:** `lib/core/crypto/signatures.dart` (line 24)

**Problem:** `SecureKey.fromList(sodium, privateKey)` is called on **every packet send** (in `MeshService.sendPacket` and `MeshService.broadcastPacket`). This allocates and zeroes a locked memory region for each signature operation.

**Fix:** Cache the signing `SecureKey` in `IdentityManager` and pass it through, or add a `signWithCachedKey()` method.

**Impact:** Reduces per-packet memory allocation overhead significantly for high-throughput scenarios.

---

### 1.7 — `broadcastPacket` in `BleTransport` writes sequentially to all peers

**File:** `lib/core/transport/ble_transport.dart` (line 564–576)

**Problem:** Each peer write is awaited sequentially in a `for` loop. If one BLE write blocks or times out, all other peers wait.

**Fix:** Use `Future.wait()` for parallel writes:
```dart
await Future.wait(
  _peerCharacteristics.entries.map((entry) async {
    try {
      var sendData = data;
      if (_noiseSessionManager.hasSession(entry.key)) {
        final encrypted = _noiseSessionManager.encrypt(data, entry.key);
        if (encrypted != null) sendData = encrypted;
      }
      await entry.value.write(sendData, withoutResponse: true);
    } catch (e) {
      _log('Failed to send to ${entry.key}: $e');
    }
  }),
);
```

**Impact:** With 7 connected peers, broadcast latency drops from `7 × BLE_write_time` to `max(BLE_write_time)` — a potential **~5–7× improvement** in broadcast completion time.

---

## 2. 🟠 Medium-Impact Optimizations

### 2.1 — `ChatController._handleReceipt()` copies the entire message list on every receipt

**File:** `lib/features/chat/chat_controller.dart` (line 114)

**Problem:** `final messages = [...state.messages]` creates a full copy (up to 200 items) on every receipt event. Combined with `state = state.copyWith(messages: messages)`, this triggers a full rebuild of the chat UI.

**Fix:** Only copy + update if the receipt actually changes something:
```dart
Future<void> _handleReceipt(ReceiptEvent receipt) async {
  final index = state.messages.indexWhere((m) => m.id == receipt.originalMessageId);
  if (index == -1) return;
  final msg = state.messages[index];
  if (!msg.isLocal) return;

  // Build updated message, compare before copying
  final newMsg = _applyReceipt(msg, receipt);
  if (newMsg == msg) return; // No change

  final messages = [...state.messages];
  messages[index] = newMsg;
  state = state.copyWith(messages: messages);
  await _persistMessages();
}
```

**Impact:** Reduces unnecessary UI rebuilds and List allocations when duplicate receipts arrive.

---

### 2.2 — `ChatScreen._scrollToBottom()` called on every build when messages exist

**File:** `lib/features/chat/chat_screen.dart` (line 279–281)

**Problem:** `_scrollToBottom()` is called unconditionally during `build()` whenever `messages.isNotEmpty`. This means every `ref.watch(chatControllerProvider)` rebuild — including receipt-status updates — triggers an animation scroll.

**Fix:** Move scrolling into the `ref.listen` callback where new messages are detected (it's already partially there, lines 252–273), and remove the unconditional call:
```dart
// Remove this:
// if (messages.isNotEmpty) { _scrollToBottom(); }

// Instead, add to the ref.listen callback:
if (incoming.isNotEmpty || newMessages.any((m) => m.isLocal)) {
  _scrollToBottom();
}
```

**Impact:** Prevents jarring scroll-jumps when only receipt status changes.

---

### 2.3 — `_sendDiscoveryAnnounce` and `_sendTopologyAnnounce` are nearly identical

**File:** `lib/core/mesh/mesh_service.dart` (lines 336–361)

**Problem:** Both methods encode the same neighbor list and build nearly identical packets. The only difference is the `MessageType`.

**Fix:** Extract a shared helper:
```dart
Future<void> _sendAnnounce(MessageType type) async {
  final neighborIds = _currentPeers.map((p) => p.peerId).toList();
  final payload = BinaryProtocol.encodeDiscoveryPayload(neighbors: neighborIds);
  final packet = BinaryProtocol.buildPacket(
    type: type,
    sourceId: _myPeerId,
    payload: payload,
    ttl: FluxonPacket.maxTTL,
  );
  await _rawTransport.broadcastPacket(packet);
}
```

**Impact:** DRY improvement; also avoids encoding the neighbor list twice during `_onPeersChanged`.

---

### 2.4 — `TopologyTracker._routeCache` is invalidated on EVERY update

**File:** `lib/core/mesh/topology_tracker.dart` (line 43, 52, 68)

**Problem:** `_routeCache.clear()` is called on every `updateNeighbors()`, `removePeer()`, and `prune()`. With periodic 45s topology announces from multiple peers, the cache is cleared before it can provide any benefit.

**Fix:** Use more granular invalidation — only clear entries that involve the changed peer:
```dart
void _invalidateRoutesInvolving(String peerId) {
  _routeCache.removeWhere((key, _) => key.contains(peerId));
}
```

**Impact:** Route cache hit rate increases from ~0% to meaningful, reducing BFS calls.

---

### 2.5 — `LocationController` creates new Map on every location update

**File:** `lib/features/location/location_controller.dart` (line 66–68)

**Problem:** `{...state.memberLocations, update.peerId: update}` creates a new `Map` on every location update from any peer.

**Fix:** For the common case where only one value changes, this is unavoidable with immutable state. However, consider checking if the value actually changed:
```dart
void _listenForLocationUpdates() {
  _locationSub = _repository.onLocationReceived.listen((update) {
    final existing = state.memberLocations[update.peerId];
    if (existing?.latitude == update.latitude &&
        existing?.longitude == update.longitude) return; // No change
    state = state.copyWith(
      memberLocations: {...state.memberLocations, update.peerId: update},
    );
  });
}
```

**Impact:** Avoids unnecessary Map copies and widget rebuilds for duplicate/unchanged location updates.

---

### 2.6 — `MessageStorageService` re-encrypts the entire message file on every save

**File:** `lib/core/services/message_storage_service.dart` (line 216–222)

**Problem:** Every `_writeEncrypted` call JSON-encodes and re-encrypts ALL messages for the group. With 200 messages and frequent receipt updates, this is expensive.

**Mitigation (already partially in place):** The debounce timer + batch size help. But consider:
- Only persist when there are actual content changes (not just receipt status updates, since receipts aren't serialized anyway — they're transient).

**Fix in `ChatController._handleReceipt`:** Don't call `_persistMessages()` since receipt status (`deliveredTo`, `readBy`) is excluded from `toJson()`:
```dart
// In _handleReceipt, remove:
// await _persistMessages(); // Receipt status is transient — no need to persist
```

**Impact:** Eliminates unnecessary disk I/O and encryption work on every receipt event.

---

### 2.7 — `GroupCipher.encrypt/decrypt` allocates a new `SecureKey` per call

**File:** `lib/core/identity/group_cipher.dart` (line 46, 74)

**Problem:** `SecureKey.fromList(sodium, groupKey)` is called on every message encrypt and decrypt. For chat messages arriving rapidly, this is a hot path.

**Fix:** Cache the `SecureKey` in `FluxonGroup` or `GroupManager` and reuse it. Dispose on `leaveGroup()`.

**Impact:** Reduces memory allocation pressure on the crypto hot path.

---

## 3. 🟡 Low-Impact / Code-Quality Improvements

### 3.1 — `MessageType.fromValue()` uses linear scan

**File:** `lib/core/protocol/message_types.dart` (line 51–56)

**Problem:** Linear search through all enum values on every packet decode.

**Fix:**
```dart
static final _valueMap = {for (final t in MessageType.values) t.value: t};
static MessageType? fromValue(int value) => _valueMap[value];
```

**Impact:** O(1) vs O(n) for 14 enum values — negligible but cleaner.

---

### 3.2 — `NotificationSoundService` is instantiated inside `ChatScreen` State

**File:** `lib/features/chat/chat_screen.dart` (line 21)

**Problem:** Every time `_ChatScreenState` is created, a new `NotificationSoundService` is created. This isn't a Riverpod provider, so there's no lifecycle management from the DI system.

**Fix:** Make it a Riverpod provider or inject it.

---

### 3.3 — `_HomeScreen` uses `IndexedStack` for 4 screens

**File:** `lib/app.dart` (line 108–111)

**Problem:** `IndexedStack` keeps all 4 screens (Chat, Map, Emergency, Device) in the widget tree simultaneously. The Location and Emergency screens may be doing GPS polling or transport listening even when not visible.

**Mitigation:** This is intentional for preserving scroll state, and the controllers already handle their own lifecycle. However, if memory is a concern on lower-end devices, consider lazy-loading non-visible tabs.

---

### 3.4 — `_maybeRelay` in `MeshService` uses `Future.delayed` for jitter

**File:** `lib/core/mesh/mesh_service.dart` (line 272–274)

**Problem:** `Future.delayed` creates a timer for every relayed packet. Under high relay load, this floods the event loop with timers.

**Fix:** Consider batching relays with a single periodic timer for better event-loop hygiene.

---

### 3.5 — `EmergencyAlertType.values.firstWhere` in `MeshEmergencyRepository`

**File:** `lib/features/emergency/data/mesh_emergency_repository.dart` (line 64–66)

**Problem:** `EmergencyAlertType.values.firstWhere(...)` scans the enum list on every incoming alert.

**Fix:** Pre-compute a `Map<int, EmergencyAlertType>`:
```dart
static final _typeMap = {for (final t in EmergencyAlertType.values) t.value: t};
// Then: final type = _typeMap[payload.alertType] ?? EmergencyAlertType.sos;
```

---

### 3.6 — `chat_screen.dart` `ref.listen` builds `prevIds` set on every state change

**File:** `lib/features/chat/chat_screen.dart` (line 265)

**Problem:** `{for (final m in prevMessages) m.id}` creates a `Set` of up to 200 IDs on every chat state change, even for receipt-only updates.

**Fix:** Guard with the existing early-return check (already present at line 262), and only build the set if new messages are actually detected.

---

### 3.7 — `Deduplicator._cleanupOldEntries` and `_trimIfNeeded` have duplicated compaction logic

**File:** `lib/core/mesh/deduplicator.dart` (lines 90–93, 101–105)

**Problem:** Both methods individually check `if (_head > _entries.length ~/ 4)` and compact. This is duplicated logic.

**Fix:** Extract a `_maybeCompact()` helper.

---

### 3.8 — `FluxonPacket.withDecrementedTTL()` and `FluxonPacket.withSignature()` copy all byte arrays

**File:** `lib/core/protocol/packet.dart` (lines 52–63, 167–178)

**Problem:** Both methods use `Uint8List.fromList()` to deep-copy `sourceId`, `destId`, `payload`, and `signature`. If the packet is only used for relaying and then discarded, the copies are wasted.

**Fix:** Consider making packets immutable by default and only copying when the original source buffer may be reused. This is a design trade-off rather than a clear bug.

---

### 3.9 — `KeyStorage` reads/writes sequentially not in parallel

**File:** `lib/core/crypto/keys.dart` (lines 70–82, 122–133)

**Problem:** `storeStaticKeyPair` and `storeSigningKeyPair` do two sequential `await _storage.write()` calls.

**Fix:**
```dart
await Future.wait([
  _storage.write(key: _staticPrivateKeyTag, value: ...),
  _storage.write(key: _staticPublicKeyTag, value: ...),
]);
```

**Impact:** Reduces startup time by parallelizing secure storage I/O.

---

### 3.10 — `MeshService._onPeersChanged` re-compute neighbor list twice

**File:** `lib/core/mesh/mesh_service.dart` (lines 324, 337, 351)

**Problem:** `_currentPeers.map((p) => p.peerId).toList()` is computed once in `_topology.updateNeighbors` (line 324), then again in `_sendDiscoveryAnnounce` (line 337) and `_sendTopologyAnnounce` (line 351) — three times total.

**Fix:** Compute once and pass to all callers:
```dart
final neighborIds = _currentPeers.map((p) => p.peerId).toList();
_topology.updateNeighbors(source: _myPeerId, neighbors: neighborIds);
// ... reuse neighborIds in _sendDiscoveryAnnounce / _sendTopologyAnnounce
```

---

## 4. 📋 Summary & Prioritized Action Items

| Priority | Item | File(s) | Effort | Impact |
|----------|------|---------|--------|--------|
| **P0** | Unify & optimize hex encoding (1.2) | `hex_utils.dart`, `keys.dart`, `transport.dart`, `packet.dart` | Low | High — hot path |
| **P0** | Cache `FluxonPacket.packetId` (1.4) | `packet.dart` | Trivial | High — every packet |
| **P0** | Cache `PeerId.hashCode` (1.3) | `peer_id.dart` | Trivial | High — every Map/Set op |
| **P1** | Replace `List.removeAt(0)` with `Queue` in gossip (1.5) | `gossip_sync.dart` | Low | High under load |
| **P1** | Parallel BLE writes in `broadcastPacket` (1.7) | `ble_transport.dart` | Low | High — multi-peer latency |
| **P1** | Remove unnecessary `_persistMessages` in receipt handler (2.6) | `chat_controller.dart` | Trivial | Med — reduces disk I/O |
| **P1** | Cache SigningKey SecureKey allocation (1.6) | `signatures.dart`, `identity_manager.dart` | Medium | Med-High |
| **P2** | Deduplicate `_bytesEqual` (1.1) | 3 files | Low | Code quality |
| **P2** | Merge `_sendDiscoveryAnnounce`/`_sendTopologyAnnounce` (2.3) | `mesh_service.dart` | Low | DRY + skip double encoding |
| **P2** | Granular route cache invalidation (2.4) | `topology_tracker.dart` | Medium | Med — cache hit rate |
| **P2** | Skip unchanged location updates (2.5) | `location_controller.dart` | Low | Med — fewer rebuilds |
| **P2** | Skip full-list copy in receipt handler when no change (2.1) | `chat_controller.dart` | Low | Med |
| **P2** | Fix unconditional `_scrollToBottom` in build (2.2) | `chat_screen.dart` | Low | UX improvement |
| **P2** | Cache GroupCipher SecureKey (2.7) | `group_cipher.dart`, `group_manager.dart` | Medium | Med |
| **P3** | Use Map for `MessageType.fromValue` (3.1) | `message_types.dart` | Trivial | Negligible |
| **P3** | Use Map for `EmergencyAlertType` lookup (3.5) | `mesh_emergency_repository.dart` | Trivial | Negligible |
| **P3** | Parallel secure storage writes (3.9) | `keys.dart` | Low | Slightly faster startup |
| **P3** | Extract deduplicator compaction helper (3.7) | `deduplicator.dart` | Trivial | Code quality |

---

### Overall Assessment

The codebase is **well-architected** — clean separation of concerns (Repository pattern, DIP via interfaces, SRP for crypto), solid security posture, and well-documented code. The optimizations above are focused on:

1. **Hot-path allocation reduction** (hex encoding, SecureKey, packet ID)
2. **Algorithmic improvements** (Queue vs List, Map vs linear scan)
3. **I/O parallelism** (BLE broadcasts, secure storage writes)
4. **Unnecessary work elimination** (receipt persistence, scroll-to-bottom, cache invalidation)

The **P0 items** alone should yield noticeable improvement in packet processing throughput and reduced GC pressure on mobile devices.
