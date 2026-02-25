# 🔍 Deep-Dive Audit: V4 — Mesh Networking

**Date:** 2026-02-25
**Scope:**
- `lib/core/mesh/mesh_service.dart`
- `lib/core/mesh/topology_tracker.dart`
- `lib/core/mesh/gossip_sync.dart`
- `lib/core/mesh/deduplicator.dart`
- `lib/core/mesh/relay_controller.dart`
- `lib/core/transport/transport_config.dart` (constants reference)

**Dependencies:** V3 (BLE Transport), V6 (Protocol), V1 (Crypto / Signatures, IdentityManager)
**Depended on by:** V9 Chat, V10 Location, V11 Emergency
**Trust boundary:** Untrusted zone — `MeshService` receives and relays packets from potentially malicious remote BLE peers. All sourceId, ttl, payload, and signature fields must be treated as attacker-controlled input.

---

## Summary

The mesh layer has received meaningful hardening in prior cycles: topology poisoning is blocked by requiring verified signatures before `updateNeighbors` is called; relay requires TTL > 1; TTL is clamped to `maxTTL`; peer signing-key maps are LRU-capped; gossip sync responses are rate-limited per-peer; and deduplication prevents relay storms from repeated identical packets.

Despite this, six findings of material security significance remain. The most important: (1) `_maybeRelay` is fire-and-forget after `stop()` — a race that can relay one additional packet per in-flight async chain; (2) the gossip sync `_syncRateByPeer` map is unbounded and can be exhausted by an attacker using many spoofed source IDs; (3) handshake packets bypass all signature verification and are relayed and delivered to the application layer without any authentication check; (4) `peerHasIds` in `handleSyncRequest` is fully attacker-controlled and allows unbounded memory allocation; (5) topology neighbor-count is not validated before `updateNeighbors` stores a potentially very large set; and (6) gossip sync records packets from unverified sources before the verification check completes, enabling relay bypass via gossip.

---

## Findings

### [HIGH] Relay Continues After `stop()` Due to Unawaited Async Fire-and-Forget

**File:** `lib/core/mesh/mesh_service.dart`, lines 298–329
**Lens:** 2 (State Management & Race Conditions), 3 (Error Handling & Recovery)

**Description:**
`_maybeRelay` is `async` and applies a jitter delay (`await Future.delayed(Duration(milliseconds: decision.delayMs))`). It is called with `_maybeRelay(packet)` — no `await` and no assignment — making it a fire-and-forget async call. When `stop()` is called, it cancels `_packetSub` and `_peersSub` and nulls the timers. However, any `_maybeRelay` calls already in-flight (suspended at the `await Future.delayed(...)`) continue to execute after `stop()` returns. The method body has no guard that checks whether the service is still running before calling `_rawTransport.broadcastPacket(relayed)`.

**Exploit/Impact:**
A burst of packets with high-jitter relay decisions sent just before app backgrounding can cause relay traffic after the foreground service intent to stop. If `dispose()` is called (closing `_appPacketController`) while a relay is in flight, a `StateError: Cannot add event after closing` can be thrown on the broadcast controller. In test environments, calling `stop()` then verifying no relay occurs within a timing window produces intermittent false-passes.

**Remediation:**
Add a `bool _running = false;` flag set to `true` in `start()` and `false` at the top of `stop()`. Add a guard at the beginning of `_maybeRelay` and after the `await Future.delayed(...)`:

```dart
if (!_running) return;
```

---

### [MEDIUM] Gossip Sync `_syncRateByPeer` Map Grows Unbounded Under Peer-ID Spoofing

**File:** `lib/core/mesh/gossip_sync.dart`, lines 82–123, 147–149
**Lens:** 5 (Resource Management), 4 (Security)

**Description:**
`handleSyncRequest` indexes `_syncRateByPeer` by the hex-encoded `fromPeerId`. The map is only cleaned up inside `_cleanupExpired`, which runs on the 60-second maintenance timer. There is no cap on the number of distinct entries the map can hold. A malicious peer can send gossip sync requests using a new random `fromPeerId` on every request, causing a new `_SyncRateState` allocation with no eviction until the next 60-second cycle.

**Exploit/Impact:**
Memory exhaustion on low-RAM mobile devices. With a 60-second window and new peer IDs arriving at BLE scan rate, an attacker can accumulate ~30 map entries per maintenance cycle. In a sustained attack with spoofed 32-byte IDs, this can accumulate thousands of entries between maintenance runs.

**Remediation:**
Cap `_syncRateByPeer` at a fixed maximum size (e.g., 200 entries). When the cap is reached, evict the entry with the oldest `windowStart` before inserting a new one. A `LinkedHashMap` ordered by insertion time provides O(1) eviction. Document explicitly that `handleSyncRequest` must only be called with authenticated peer IDs.

---

### [MEDIUM] Handshake Packets Bypass All Signature Verification and Are Unconditionally Delivered to the App Layer

**File:** `lib/core/mesh/mesh_service.dart`, lines 197–226
**Lens:** 4 (Security & Cryptography), 1 (Input Validation)

**Description:**
The verification logic sets `verified = true` unconditionally when `packet.type == MessageType.handshake`:

```dart
bool verified = packet.type == MessageType.handshake;
```

Unsigned handshake packets from any source pass as `verified = true`. Handshake packets with a forged signature are never checked against any key. They are emitted to the app stream and then `_maybeRelay`'d with full TTL=6 relay priority across the mesh.

**Exploit/Impact:**
An attacker can send crafted handshake payloads targeting any peer ID to attempt Noise XX state machine manipulation (e.g., injecting a fake message 1 or message 3 to force session teardown, key confusion, or re-key triggering). The blast radius is the entire mesh network. Receiving an unsolicited message 1 from a peer that already has an active session may trigger a session teardown — a denial-of-service vector.

The BleTransport-level handshake rate limit (5 per peer per 60s, v2.6 fix) does NOT protect against multi-hop-relayed injected handshakes since the relaying nodes see only the relay, not a new handshake initiation from a direct peer.

**Remediation:**
Short-term mitigations:
1. Rate-limit handshake packets per unique sourceId at the MeshService level (a separate `_handshakeRateLimit` map similar to `_syncRateByPeer`).
2. Cap total in-progress handshake sessions in `NoiseSessionManager` to prevent state exhaustion.
3. Apply a lower TTL cap specifically for handshake packets (e.g., cap at 3 rather than 6) to limit propagation distance of injected handshakes.

---

### [MEDIUM] `peerHasIds` Set in `handleSyncRequest` Is Fully Attacker-Controlled — Unbounded Allocation

**File:** `lib/core/mesh/gossip_sync.dart`, lines 89–123
**Lens:** 1 (Input Validation), 5 (Resource Management)

**Description:**
`handleSyncRequest` accepts a `Set<String> peerHasIds` parameter derived from the gossip sync request packet's payload. There is no validation of the size of this set before the call. A malicious peer can craft a gossip sync request payload containing an arbitrarily large set of packet IDs.

**Exploit/Impact:**
If the calling layer passes a decoded set of unbounded size, heap allocation of O(n) strings occurs. At 64 bytes per hex ID string plus Map overhead, 100,000 entries would consume approximately 10–20 MB per request.

**Remediation:**
Add a guard inside `handleSyncRequest`:

```dart
if (peerHasIds.length > config.seenCapacity * 2) return; // Reject oversized sets
```

Also ensure the gossip sync request decoder caps the number of IDs it will parse from the wire.

---

### [LOW] Topology Neighbor Count Not Capped — `updateNeighbors` Can Store Unbounded Neighbor Sets Per Node

**File:** `lib/core/mesh/topology_tracker.dart`, lines 29–45
**Lens:** 5 (Resource Management), 1 (Input Validation)

**Description:**
`updateNeighbors` filters neighbors by exact 32-byte size, but does not cap the number of neighbors stored per source node. The existing 10-neighbor cap in `BinaryProtocol.decodeDiscoveryPayload` is the only enforcement, but `TopologyTracker.updateNeighbors` itself imposes no such cap. Any future code path calling `updateNeighbors` directly without going through `BinaryProtocol` can bypass this limit.

**Exploit/Impact:**
If a future call path passes a large `neighbors` list, `_claims[srcId]` can hold an unbounded set. With 1000 nodes each claiming 1000 neighbors, `_claims` would hold 1,000,000 string entries.

**Remediation:**
Add a constant `static const int _maxNeighborsPerNode = 20;` inside `TopologyTracker` and truncate `validNeighbors` if it would exceed this limit after filtering. This makes the invariant explicit at the data structure level.

---

### [LOW] `_invalidateRoutesFor` Re-encodes Intermediate Hops on Every Topology Update — O(n×m) String Allocation

**File:** `lib/core/mesh/topology_tracker.dart`, lines 156–169
**Lens:** 8 (Performance & Scalability)

**Description:**
`_invalidateRoutesFor(nodeId)` scans each cached route's `List<Uint8List>` intermediate hops for a match via `HexUtils.encode(hop) == nodeId`, re-encoding each hop to hex on every call. With 1000 cache entries each holding a 7-hop route and `_invalidateRoutesFor` called on every topology update, this is O(cache_size × max_hops) string allocation per update.

**Exploit/Impact:**
A topology-thrashing attack (frequent `updateNeighbors` calls from many peers) causes O(n×m) string allocations per topology update event, saturating the GC.

**Remediation:**
Cache intermediate hops in the route cache as hex strings rather than `Uint8List` objects, eliminating the per-invalidation re-encoding. Alternatively, maintain a reverse index from nodeId to cache keys.

---

### [LOW] Deduplicator `record()` Stores Caller-Supplied Timestamp — Future Timestamps Can Deceive Freshness Checks

**File:** `lib/core/mesh/deduplicator.dart`, lines 43–49
**Lens:** 6 (Data Integrity), 5 (Resource Management)

**Description:**
`record(String id, DateTime timestamp)` stores the caller's `timestamp` in `_lookup` (for retrieval via `timestampFor`) but wall-clock time in `_entries` (for age-based cleanup). If a caller passes a `timestamp` far in the future (e.g., `DateTime(2099, 1, 1)`), `timestampFor(id)` will return that future time. Any code using `timestampFor` for freshness decisions could be confused by the attacker-supplied future timestamp.

**Exploit/Impact:**
Low: callers that use `timestampFor` for freshness decisions could be deceived. No immediate known exploit in the current codebase, but a latent bug.

**Remediation:**
Document clearly that the `timestamp` parameter is stored verbatim and callers must validate it before passing. Alternatively, always store `DateTime.now()` in both `_lookup` and `_entries`.

---

### [LOW] `_maybeRelay` Does Not Re-Check Deduplication Before Broadcasting

**File:** `lib/core/mesh/mesh_service.dart`, lines 298–335
**Lens:** 6 (Data Integrity), 8 (Performance)

**Description:**
`_onPacketReceived` calls `_meshDedup.isDuplicate(packet.packetId)` at entry. However, `_maybeRelay` creates a new `FluxonPacket` with the same `packetId` and broadcasts it up to 220ms later. In the jitter window, the same packet could arrive via a second path, be deduplicated correctly, but the relay still fires without rechecking — sending a packet to peers that may already have it.

**Remediation:**
Before calling `_rawTransport.broadcastPacket(relayed)` inside `_maybeRelay`, re-check deduplication status to avoid redundant relay in the jitter window.

---

### [INFO] Route-Cache Key Uses `maxHops` — Unbounded Distinct Cache Entries for Same Source/Target Pair

**File:** `lib/core/mesh/topology_tracker.dart`, lines 88–93
**Lens:** 8 (Performance & Scalability), 5 (Resource Management)

**Description:**
The route cache key is `"$source:$target:$maxHops"`. Any caller passing a different `maxHops` creates a distinct cache slot. The route cache has no independent size cap beyond natural TTL expiration.

**Remediation:**
Cap the route cache at a fixed size (e.g., 500 entries) with LRU eviction, or restrict `maxHops` to a small set of valid values.

---

### [INFO] `GossipSyncManager` Copies `knownPacketIds` on Every Call

**File:** `lib/core/mesh/gossip_sync.dart`, line 127
**Lens:** 8 (Performance & Scalability), 7 (API Contract)

**Description:**
`knownPacketIds` returns `_seenPackets.keys.toSet()`, creating a full copy of up to 1000 strings on every call. With 6 direct peers and one copy per sync round, this allocates 6 sets of 1000 strings per sync round.

**Remediation:**
Return an `UnmodifiableSetView` wrapping the live keys, or expose `knownPacketIds` as a `Set<String>` that wraps the map keys directly.

---

## Cross-Module Boundary Issues

### MeshService → GossipSyncManager (Authentication Responsibility Gap)

`MeshService._onPacketReceived` calls `_gossipSync.onPacketSeen(packet)` at line 229, **before** the topology/direct-peer authentication checks complete. This means gossip sync records packets from unverified sources. An unverified direct peer's packets are added to gossip sync's `_seenPackets` and may later be re-sent to other peers in response to sync requests — a subtle bypass where a malicious direct peer whose packets are dropped at the app layer can still get its packets replayed to distant nodes via gossip sync.

**Fix:** Move `_gossipSync.onPacketSeen(packet)` to after the full verification and delivery checks pass.

### BleTransport → MeshService (Handshake Rate Limit Gap for Multi-Hop)

`BleTransport` rate-limits handshake initiation at the BLE connection level (5 per peer per 60s, v2.6). However, `MeshService` relays handshake packets from multi-hop sources without applying any rate limit. A distant attacker (2–7 hops away) can inject handshake packets relayed by intermediate nodes without triggering the BleTransport-level limit.

### TopologyTracker Neighbor Cap Relies on BinaryProtocol

The 10-neighbor cap is enforced in `BinaryProtocol.decodeDiscoveryPayload`, not in `TopologyTracker.updateNeighbors`. The `_onPeersChanged` path (line ~362) is safe today (bounded by `maxConnections=7`) but this is an invisible invariant with no enforcement at the `TopologyTracker` API boundary.

---

## Test Coverage Gaps

1. **No test for the `stop()` race with in-flight `_maybeRelay`.** Existing tests call `stop()` before simulating the incoming packet, avoiding the race. No test simulates: inject packet → await jitter start → call `stop()` → verify no relay broadcast occurs after stop.
2. **No test for gossip sync `_syncRateByPeer` map growth under spoofed peer IDs.**
3. **No test for `handleSyncRequest` with an oversized `peerHasIds` set.**
4. **No test for handshake relay rate limiting at the MeshService level** (multi-hop injected handshakes).
5. **No test for `updateNeighbors` with a very large `neighbors` list** (e.g., 1000 entries).
6. **No test that verifies `_gossipSync.onPacketSeen` is NOT called for packets subsequently dropped by the direct-peer verification check.**
7. **No test for `computeRoute` with `maxHops=0` or `maxHops=INT_MAX`.**
8. **The test `degree=0 does NOT relay` contains no assertion beyond "no crash"** — it does not verify that relay either does or does not occur.

---

## Positive Properties

1. **Topology poisoning is effectively blocked.** The combination of requiring verified signatures before `updateNeighbors` and the two-way edge requirement in `TopologyTracker.computeRoute` makes single-node topology injection very difficult.
2. **TTL clamping enforced at the relay layer.** A packet arriving with `ttl=255` is clamped to 7 before relay.
3. **Deduplication is robust and efficient.** The `MessageDeduplicator` uses a backed-list with O(1) front removal, LRU eviction at 75% retention, and 25%-threshold compaction.
4. **Gossip sync per-peer rate limiting is non-trivially correct.** `rateState.count` persists across multiple calls within the same 60-second window, correctly enforcing the budget.
5. **Relay jitter correctly uses `Random.secure()`**, preventing timing attacks that could reconstruct relay paths from deterministic delay patterns.
6. **Route cache uses granular invalidation** (`_invalidateRoutesFor`) rather than full cache clear on every topology update.
7. **`_peerSigningKeys` is LRU-capped at 500 entries**, preventing memory exhaustion from transient peers.
8. **Signature verification correctly distinguishes verified vs. unverified peers** and drops unsigned packets from peers whose signing key is already known, preventing signature-stripping attacks.
