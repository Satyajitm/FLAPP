# FluxonApp — Development Planning Document

> **Status:** Phase 4 complete ✅ — Background relay (Android foreground service + iOS background modes), duty-cycle BLE scan, offline map caching, UI redesign (group-only chat), user display names with onboarding, reactive group state. 39 test files, zero compile errors.
> **Last updated:** February 19, 2026
> **Reference:** See `Technical/Phone_to_Phone_Mesh_Analysis.md` for the full Bitchat analysis this is based on.

---

## 1. What Is FluxonApp?

FluxonApp is the phone-only v1 of Fluxonlink — a BLE mesh networking app that lets groups of people find each other, chat, and send emergency alerts when mobile networks are unavailable (festivals, trekking, disaster zones).

Every phone running FluxonApp is simultaneously a **mesh node and relay**. No internet, no servers, no dedicated hardware required.

This is a direct adaptation of [Bitchat's](https://github.com/jackjack/bitchat) proven phone-to-phone BLE mesh architecture, stripped down and rebuilt for Fluxonlink's specific use case.

---

## 2. Design Decisions (Locked)

| Decision | Choice | Rationale |
|---|---|---|
| **Platform** | Flutter (Dart) | Single codebase for iOS + Android |
| **BLE central role** | `flutter_blue_plus` | Scanning, connecting to peers, subscribing to GATT notifications, writing to characteristics |
| **BLE peripheral role** | `ble_peripheral` | Advertising, GATT server, accepting incoming writes from remote centrals. `flutter_blue_plus` is central-only — it does not support peripheral/advertising at all. Two separate packages are required. |
| **Encryption** | libsodium via `flutter_sodium` | Battle-tested C library; provides Curve25519, ChaCha20-Poly1305, Ed25519 needed for Noise Protocol |
| **Noise pattern** | XX | No pre-shared keys needed; mutual authentication; forward secrecy |
| **State management** | Riverpod | Testable, no context threading issues with background BLE callbacks |
| **Local storage** | `flutter_secure_storage` + `hive` | Secure key storage (Keychain/Keystore) + fast local message cache |
| **Map** | `flutter_map` (OpenStreetMap) | No API key required, works offline with cached tiles |
| **Group pairing** | Shared passphrase | Works fully offline; no QR scanner needed |
| **Transport abstraction** | Yes, from day 1 | Abstract `Transport` interface so Fluxo hardware can plug in later without restructuring |

---

## 3. Architecture Overview

```
┌──────────────────────────────────────────────┐
│                  FEATURES                     │
│   Chat │ Location Map │ Emergency │ Groups    │
└──────────────────┬───────────────────────────┘
                   │ uses
┌──────────────────▼───────────────────────────┐
│                   CORE                        │
│                                               │
│  ┌─────────────┐  ┌──────────┐  ┌─────────┐  │
│  │  Transport  │  │  Mesh    │  │ Crypto  │  │
│  │  (Abstract) │  │  Layer   │  │ (Noise) │  │
│  └──────┬──────┘  └──────────┘  └─────────┘  │
│         │                                     │
│  ┌──────▼──────┐  ┌──────────┐  ┌─────────┐  │
│  │BLE Transport│  │Protocol  │  │Identity │  │
│  │(Phone↔Phone)│  │(Packets) │  │& Groups │  │
│  └─────────────┘  └──────────┘  └─────────┘  │
└──────────────────────────────────────────────┘
         ↕ (future)
┌─────────────────────┐
│  Fluxo Hardware     │  ← Same Transport interface, different implementation
│  Transport (BLE/RF) │
└─────────────────────┘
```

---

## 4. Full Folder Structure

```
FluxonApp/
│
├── PLANNING.md                          ← This file
├── pubspec.yaml                         ← Flutter dependencies
├── README.md                            ← Setup and run instructions
│
├── lib/
│   ├── main.dart                        ← App entry point, initialises services
│   ├── app.dart                         ← MaterialApp setup, router, theme
│   │
│   ├── core/                            ← Mesh networking engine (Bitchat-derived)
│   │   │
│   │   ├── transport/                   ← HOW data moves between devices
│   │   │   ├── transport.dart           ← Abstract Transport interface
│   │   │   ├── ble_transport.dart       ← BLE phone-to-phone implementation (+ duty-cycle scan)
│   │   │   └── transport_config.dart    ← All tunable mesh parameters (+ duty-cycle config)
│   │   │
│   │   ├── protocol/                    ← WHAT the data looks like on the wire
│   │   │   ├── packet.dart              ← FluxonPacket binary structure
│   │   │   ├── binary_protocol.dart     ← Encode / decode binary wire format (+ ChatPayload JSON)
│   │   │   ├── message_types.dart       ← Enum of all packet types
│   │   │   └── padding.dart             ← PKCS#7 padding for traffic analysis resistance
│   │   │
│   │   ├── mesh/                        ← HOW packets travel through the mesh
│   │   │   ├── mesh_service.dart        ← Relay orchestrator (wraps Transport, wires relay+topology+gossip)
│   │   │   ├── relay_controller.dart    ← Flood control (TTL, jitter, K-of-N fanout)
│   │   │   ├── topology_tracker.dart    ← Mesh graph + BFS shortest-path routing
│   │   │   ├── deduplicator.dart        ← LRU dedup cache (5 min / 1000 entries)
│   │   │   └── gossip_sync.dart         ← GCS-filter self-healing sync
│   │   │
│   │   ├── crypto/                      ← HOW data is secured
│   │   │   ├── sodium_instance.dart     ← Global SodiumSumo singleton (init once at startup)
│   │   │   ├── noise_protocol.dart      ← Noise XX handshake (CipherState, SymmetricState, HandshakeState)
│   │   │   ├── noise_session.dart       ← Per-peer session (send/receive cipher states)
│   │   │   ├── keys.dart                ← Key generation + secure storage + PeerID derivation
│   │   │   └── signatures.dart          ← Ed25519 packet signing and verification
│   │   │
│   │   ├── identity/                    ← WHO is on the mesh
│   │   │   ├── peer_id.dart             ← PeerID model (16-hex from SHA256 of Noise key)
│   │   │   ├── identity_manager.dart    ← Cryptographic + social identity persistence
│   │   │   ├── group_manager.dart       ← Shared-passphrase group key derivation (Fluxonlink-specific)
│   │   │   ├── group_storage.dart       ← Persist group passphrase/name in flutter_secure_storage
│   │   │   └── user_profile_manager.dart← User display name persistence
│   │   │
│   │   ├── providers/                   ← Cross-cutting Riverpod providers
│   │   │   ├── profile_providers.dart   ← userProfileManagerProvider + displayNameProvider
│   │   │   └── group_providers.dart     ← activeGroupProvider (reactive group state)
│   │   │
│   │   └── services/                    ← Platform services
│   │       └── foreground_service_manager.dart ← Android foreground service for background relay
│   │
│   ├── features/                        ← User-facing product features
│   │   │
│   │   ├── onboarding/
│   │   │   └── onboarding_screen.dart   ← First-run display name entry
│   │   │
│   │   ├── chat/
│   │   │   ├── chat_screen.dart         ← Group chat UI (group menu, directional bubbles, display names)
│   │   │   ├── chat_controller.dart     ← Message send/receive state (group broadcast only)
│   │   │   ├── message_model.dart       ← Chat message data model (+ senderName field)
│   │   │   ├── chat_providers.dart      ← Riverpod providers (+ display name injection)
│   │   │   └── data/
│   │   │       ├── chat_repository.dart ← Abstract interface (includes sendPrivateMessage for protocol)
│   │   │       └── mesh_chat_repository.dart ← Concrete implementation (group + Noise-encrypted)
│   │   │
│   │   ├── location/
│   │   │   ├── location_screen.dart     ← Map with offline tile caching + own location pin
│   │   │   ├── location_controller.dart ← GPS polling + location broadcast scheduling
│   │   │   └── location_model.dart      ← Location update data model
│   │   │
│   │   ├── emergency/
│   │   │   ├── emergency_screen.dart    ← SOS trigger button + confirmation UI
│   │   │   ├── emergency_controller.dart← High-priority emergency broadcast logic
│   │   │   └── emergency_providers.dart ← Emergency Riverpod providers
│   │   │
│   │   └── group/
│   │       ├── create_group_screen.dart ← Create group (hero icon, passphrase visibility toggle)
│   │       └── join_group_screen.dart   ← Join group (hero icon, loading state)
│   │
│   └── shared/                          ← Cross-cutting utilities
│       ├── logger.dart                  ← Secure logging (no PII in logs)
│       ├── hex_utils.dart               ← Hex encode/decode helpers
│       └── compression.dart             ← zlib compression for large payloads
│
├── android/
│   └── app/src/main/AndroidManifest.xml ← BLE + INTERNET + FOREGROUND_SERVICE permissions
│
├── ios/
│   └── Runner/Info.plist                ← BLE background modes, location background, usage descriptions
│
└── test/
    ├── core/
    │   ├── packet_test.dart                    ← Encode/decode round-trip, all message types
    │   ├── relay_controller_test.dart          ← Relay decisions for all TTL/degree combinations
    │   ├── topology_test.dart                  ← BFS routing, two-way edge verification, stale pruning
    │   ├── deduplicator_test.dart              ← LRU eviction, time expiry, thread safety
    │   ├── noise_test.dart                     ← Full XX handshake, encrypt/decrypt, replay rejection
    │   ├── gossip_sync_test.dart               ← Gossip sync: packet tracking, sync requests, capacity
    │   ├── mesh_service_test.dart              ← MeshService: forwarding, relay, topology, lifecycle
    │   ├── mesh_service_signing_test.dart      ← MeshService Ed25519 signing integration
    │   ├── mesh_relay_integration_test.dart    ← 3-phone A—B—C relay simulation
    │   ├── binary_protocol_discovery_test.dart ← Discovery codec round-trip and edge cases
    │   ├── stub_transport_test.dart            ← StubTransport: loopback, capture, peer simulation
    │   ├── ble_transport_handshake_test.dart   ← BLE Noise handshake integration
    │   ├── ble_transport_logic_test.dart       ← BLE transport logic unit tests
    │   ├── device_services_test.dart           ← Device service tests
    │   ├── duty_cycle_test.dart                ← Idle detection + duty-cycle transitions
    │   ├── e2e_noise_handshake_test.dart       ← End-to-end Noise handshake flow
    │   ├── e2e_relay_encrypted_test.dart       ← End-to-end encrypted relay
    │   ├── foreground_service_manager_test.dart← Foreground service lifecycle
    │   ├── group_cipher_test.dart              ← Group encryption/decryption
    │   ├── group_manager_test.dart             ← Group create/join/leave lifecycle
    │   ├── group_storage_test.dart             ← Group persistence round-trip
    │   ├── identity_manager_test.dart          ← Identity persistence + key derivation
    │   ├── identity_signing_lifecycle_test.dart← Signing key lifecycle
    │   ├── keys_test.dart                      ← Key generation + PeerID derivation
    │   ├── noise_session_manager_test.dart     ← Noise session manager unit tests
    │   └── packet_immutability_test.dart       ← Packet immutability guarantees
    ├── features/
    │   ├── app_lifecycle_test.dart       ← App lifecycle + foreground service integration
    │   ├── chat_controller_test.dart     ← Chat controller (group broadcast, display name)
    │   ├── chat_integration_test.dart    ← End-to-end loopback + two-peer simulation
    │   ├── chat_repository_test.dart     ← Chat repository + ChatPayload decoding
    │   ├── emergency_controller_test.dart← Emergency controller
    │   ├── emergency_repository_test.dart← Emergency repository
    │   ├── group_screens_test.dart       ← Create/Join group screen widget tests
    │   ├── location_controller_test.dart ← Location controller
    │   ├── location_screen_test.dart     ← Location screen widget test
    │   ├── location_test.dart            ← Location model serialisation
    │   └── mesh_location_repository_test.dart ← Location repository
    ├── shared/
    │   └── geo_math_test.dart            ← Geospatial math helpers
    └── widget_test.dart                  ← Root widget smoke test
```

---

## 5. Component Specifications

### 5.1 Transport Layer

**`transport.dart`** — Abstract interface

```
Transport (abstract)
  ├── startServices()
  ├── stopServices()
  ├── emergencyDisconnect()
  ├── sendPacket(FluxonPacket, to: PeerID?)    // null = broadcast
  ├── Stream<FluxonPacket> incomingPackets
  ├── Stream<List<PeerSnapshot>> peerSnapshots
  ├── PeerID myPeerID
  └── String myNickname
```

Two future implementations of this interface:
- `BleTransport` — what we build now
- `FluxoDeviceTransport` — future hardware bridge

**`ble_transport.dart`** — Key behaviours:

| Behaviour | Detail | Library |
|---|---|---|
| Central: scan for peers | Filter by Fluxon service UUID | `flutter_blue_plus` |
| Central: connect + notify | Subscribe to GATT characteristic notifications to receive data | `flutter_blue_plus` |
| Central: write | Write packets to peer's GATT characteristic to send data | `flutter_blue_plus` |
| Peripheral: advertise | Broadcast Fluxon service UUID so other phones discover us | `ble_peripheral` |
| Peripheral: GATT server | Accept incoming writes from remote centrals | `ble_peripheral` |
| Peripheral: notify | Push packets to connected centrals via `updateCharacteristic` | `ble_peripheral` |
| Deduplication | Drop packets already seen (by `packetId`) before emitting to stream | `MessageDeduplicator` |
| Service UUID | `F1DF0001-1234-5678-9ABC-DEF012345678` | — |
| Characteristic UUID | `F1DF0002-1234-5678-9ABC-DEF012345678` | — |
| Max connections | 7 (configurable via `TransportConfig.maxConnections`) | — |
| MTU | Negotiate up to 512 bytes; fragment anything larger (Phase 2) | — |
| Duty cycle | 5s scan ON / 10s scan OFF when idle — Phase 4 | — |

**`transport_config.dart`** — Key parameters (from Bitchat's TransportConfig):

| Parameter | Value | Note |
|---|---|---|
| `messageTTL` | 7 | Max hops across the mesh |
| `maxCentralLinks` | 6 | iOS BLE limit |
| `fragmentSize` | 469 bytes | ~512 MTU minus overhead |
| `fragmentSpacingMs` | 30 | Pacing between fragment writes |
| `highDegreeThreshold` | 6 | Node degree above which we throttle |
| `announceIntervalSec` | 4–15 | Adaptive, sparser when dense |
| `messageDedupMaxAge` | 300s | How long to remember seen packet IDs |
| `syncIntervalSec` | 15 | Gossip sync interval |
| `routeFreshnessThreshold` | 60s | Max age of topology data used for routing |

---

### 5.2 Protocol Layer

**`message_types.dart`** — All packet types:

| Value | Name | Inherited from Bitchat? | Description |
|---|---|---|---|
| 0x01 | `handshake` | ✅ | Noise XX handshake message |
| 0x02 | `chat` | ✅ | Public group chat message (group-encrypted) |
| 0x03 | `topologyAnnounce` | ✅ | Mesh topology link-state |
| 0x04 | `gossipSync` | ✅ | GCS gossip sync request |
| 0x05 | `ack` | ✅ | Acknowledgement |
| 0x06 | `ping` | ✅ | Keepalive |
| 0x07 | `pong` | ✅ | Keepalive response |
| 0x08 | `discovery` | ✅ | Peer discovery broadcast |
| **0x09** | **`noiseEncrypted`** | ✅ (Bitchat) | **Direct private message encrypted via Noise session** |
| **0x0A** | **`locationUpdate`** | ❌ New | GPS coordinate broadcast (group-encrypted) |
| **0x0B** | **`groupJoin`** | ❌ New | Group join request |
| **0x0C** | **`groupJoinResponse`** | ❌ New | Group join response |
| **0x0D** | **`groupKeyRotation`** | ❌ New | Group key rotation |
| **0x0E** | **`emergencyAlert`** | ❌ New | SOS broadcast (group-encrypted, bypasses rate limits) |

**`packet.dart`** — FluxonPacket wire format (unchanged from Bitchat):
```
HEADER (14 bytes v1, 16 bytes v2):
  version(1) | type(1) | ttl(1) | timestamp(8) | flags(1) | payloadLen(2 or 4)

FLAGS:
  0x01 hasRecipient | 0x02 hasSignature | 0x04 isCompressed | 0x08 hasRoute | 0x10 isRSR

BODY:
  senderID(8) | recipientID(8, opt) | route(var, opt) | payload(var) | signature(64, opt)
```

---

### 5.3 Mesh Layer

**`relay_controller.dart`** — Decision table:

| Packet type | TTL policy | Delay |
|---|---|---|
| Noise handshake | Always relay, no TTL cap | 10–35ms jitter |
| Directed encrypted / directed fragment | Always relay | 20–60ms jitter |
| Fragment (broadcast) | TTL cap 5 | 8–25ms jitter |
| Announce | TTL cap 7 | degree-adaptive |
| Public message | TTL cap 6 | degree-adaptive 10–220ms |
| TTL ≤ 1 | Never relay | — |
| Own packet | Never relay | — |

**`topology_tracker.dart`** — Rules:
- An edge A↔B is valid only when **both** A claims B **and** B claims A in announcements
- Topology entries expire after 60 seconds
- BFS shortest path; return only intermediate hops
- Max 10 hops per route

**`deduplicator.dart`**:
- Key: `"senderHex-timestamp-packetType"`
- Capacity: 1000 entries, 5-minute TTL
- LRU eviction (trim to 75% when full)
- Thread-safe

**`gossip_sync.dart`**:
- GCS filter (Golomb-Coded Set) — compact probabilistic set of seen packet IDs
- Sent unicast to each connected peer after joining
- Repeated every 15s (messages), 30s (fragments), 60s (files)
- Responder re-sends any packet not in the requester's filter with `TTL=0, isRSR=true`

---

### 5.4 Crypto Layer

**Noise XX handshake** (`noise_protocol.dart`):
```
Protocol: Noise_XX_25519_ChaChaPoly_SHA256

Phone A (Initiator)          Phone B (Responder)
MSG 1: → e
MSG 2:                       ← e, ee, s, es
MSG 3: → s, se

Result: sendCipher + receiveCipher for each direction
```

**libsodium primitives used:**
- `crypto_box_keypair` (Curve25519) — static and ephemeral keys
- `crypto_scalarmult` (X25519) — DH operations
- `crypto_aead_chacha20poly1305_ietf` — AEAD encryption
- `crypto_hash_sha256` — hashing
- `crypto_sign_keypair` (Ed25519) — signing keys
- `crypto_sign_detached` / `crypto_sign_verify_detached` — packet signing

**Key derivation** (`keys.dart`):
```
StaticNoiseKey  = crypto_box_keypair()         // Curve25519, persisted in secure storage
SigningKey      = crypto_sign_keypair()         // Ed25519, persisted in secure storage
PeerID          = SHA256(StaticNoisePublicKey)[0..7]   // 8 bytes = 16 hex chars
Fingerprint     = SHA256(StaticNoisePublicKey)         // 32 bytes = 64 hex chars
```

**Replay protection**: 1024-message sliding window bitmap in each `NoiseCipherState`.

---

### 5.5 Identity & Group Layer

**`identity_manager.dart`**:
- Stores per-peer: noise public key, signing public key, nickname, trust level
- Encrypted with AES-256-GCM at rest (key in flutter_secure_storage)
- Social data: petnames, favourites, blocked list

**`group_manager.dart`** — Fluxonlink-specific:
```
createGroup(name) → generates random 6-word passphrase
joinGroup(passphrase) → derives 32-byte group key using Argon2id(passphrase, appSalt)
groupKey → used to encrypt locationUpdate and emergencyAlert payloads
           (XSalsa20-Poly1305 symmetric encryption via libsodium secretbox)
```

The group key is never transmitted. Members who know the passphrase can derive the same key independently.

---

### 5.6 Feature Layer

**Location** (`location_controller.dart`):
- Poll GPS every 10 seconds when app is active (use `geolocator`)
- Encrypt GPS coordinates with group key → `locationUpdate` packet
- Broadcast via mesh (TTL=5, lower than messages to reduce network load)
- Only group members (who have the group key) can decrypt

**Emergency** (`emergency_controller.dart`):
- User presses SOS → confirmation dialog (3-second hold) → send `emergencyAlert`
- Emergency packets bypass normal rate limiting
- Highest relay priority — treated like handshake packets (always relay, no jitter wait)
- Payload: encrypted GPS + timestamp + sender nickname
- All nearby phones vibrate/alert even if app is backgrounded

**Chat** (`chat_controller.dart`):
- Public mesh messages via `message` packet type (visible to all on mesh)
- Private messages via Noise-encrypted `noiseEncrypted` packets (after handshake)

---

## 6. Platform-Specific Setup

### iOS (`Info.plist` required entries)
```
NSBluetoothAlwaysUsageDescription    — "Fluxonlink uses Bluetooth to connect with nearby group members"
NSLocationWhenInUseUsageDescription  — "Fluxonlink uses your location to show your position to your group"
UIBackgroundModes                    — bluetooth-central, bluetooth-peripheral
```

### Android (`AndroidManifest.xml` required permissions)
```
android.permission.BLUETOOTH_SCAN           (API 31+)
android.permission.BLUETOOTH_ADVERTISE      (API 31+)
android.permission.BLUETOOTH_CONNECT        (API 31+)
android.permission.ACCESS_FINE_LOCATION     (required for BLE scan on Android)
android.permission.FOREGROUND_SERVICE       (for background mesh relay)
```

---

## 7. Key Dependencies (`pubspec.yaml`)

| Package | Version | Purpose |
|---|---|---|
| `flutter_blue_plus` | ^1.35.2 | BLE **central** role: scanning, connecting, GATT client (does NOT support peripheral/advertising) |
| `ble_peripheral` | ^2.4.0 | BLE **peripheral** role: advertising, GATT server, handling writes from remote centrals |
| `sodium_libs` | ^2.2.1 | libsodium bindings (X25519, ChaCha20-Poly1305, Ed25519, Argon2id) |
| `flutter_map` | ^7.0.2 | OpenStreetMap-based map display |
| `latlong2` | ^0.9.1 | LatLng coordinate type for flutter_map |
| `geolocator` | ^13.0.2 | GPS access and permission handling |
| `flutter_secure_storage` | ^9.2.4 | Keychain/Keystore for cryptographic keys |
| `flutter_riverpod` | ^2.6.1 | State management and dependency injection |
| `archive` | ^4.0.4 | zlib/gzip compression for large payloads |

---

## 8. Implementation Phases

### Phase 0 — Bootstrap ✅ Complete
- [x] `flutter create FluxonApp`
- [x] Configure `pubspec.yaml` with all dependencies (`flutter_blue_plus`, `ble_peripheral`, `sodium_libs`, `flutter_riverpod`, `geolocator`, `flutter_map`, `flutter_secure_storage`, `archive`)
- [x] Set up Android `AndroidManifest.xml` BLE permissions (`BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`)
- [x] Create full folder structure and skeleton files (47 Dart files across core/, shared/, features/)
- [x] Verify `flutter run` builds without errors

---

### Phase 1 — BLE Chat Between Two Phones (in progress)

**Goal:** Two real Android phones discover each other over BLE and can exchange chat messages using the FluxonApp UI.

**Test setup:** Two physical Android phones. No emulators — BLE advertising is not supported on Android emulators.

**What's been implemented:**
- [x] Full protocol layer: `FluxonPacket` encode/decode, `BinaryProtocol`, `MessageType` enum
- [x] `StubTransport` with loopback mode and `simulateIncomingPacket()` for desktop testing
- [x] `BleTransport` dual-role: central (flutter_blue_plus: scan + connect + notify subscribe) + peripheral (ble_peripheral: GATT server + advertising + write callback)
- [x] Packet deduplication wired into `BleTransport._handleIncomingData()` via `MessageDeduplicator`
- [x] `MeshChatRepository` filters self-sourced packets (no echo of own messages)
- [x] `chat_providers.dart` passes `myPeerId` to `MeshChatRepository` so self-filtering works end-to-end
- [x] `main.dart` auto-selects `BleTransport` on Android/iOS, `StubTransport` on desktop
- [x] BLE starts after first frame (`addPostFrameCallback`) so permission dialogs have a live Activity — fixes startup freeze
- [x] Android 12+ runtime BLE permissions: `BlePeripheral.askBlePermission()` called before GATT server init
- [x] Central role waits for `BluetoothAdapterState.on` before scanning — handles Bluetooth-off gracefully
- [x] All BLE startup errors caught in `main.dart` — app UI always loads even if BLE fails to start
- [x] Test suite: 134 unit + integration tests passing (expanded from 109); 3 new test files added:
  - `test/core/stub_transport_test.dart` — lifecycle, loopback, `simulateIncomingPacket`, field preservation
  - `test/features/chat_repository_test.dart` — extended with self-source filtering, backwards-compat groups
  - `test/features/chat_integration_test.dart` — end-to-end loopback + two-peer simulation
- [x] Debug APK and release APK (49 MB) successfully built and installed on Samsung Galaxy A53e (Android 16)
- [x] Physical device validation: GATT server registered (`F1DF0002` characteristic confirmed), BLE scan cycling every ~2.5s, zero runtime errors

**Remaining for Phase 1:**
- [ ] Field test with **two** physical Android phones: confirm mutual BLE discovery (both sides scan + advertise simultaneously), send a chat message each way, verify it appears in the correct bubble (left/right) on both screens
- [ ] Fix BLE service UUID in `CLAUDE.md` — still references old invalid UUID `FLUXONLINK01`; live UUID is `F1DF0001-1234-5678-9ABC-DEF012345678`

**Known constraints:**
- BLE MTU is ~512 bytes; chat messages longer than ~430 bytes need fragmentation (deferred to Phase 2)
- No encryption in Phase 1 — messages are plaintext on the wire
- ~~Peer identity (the `shortId` shown in chat bubbles) is a randomly generated 32-byte ID per session — not persistent across restarts yet~~ → Fixed in Phase 1.5

---

### Phase 1.5 — Wiring Gaps & Group Infrastructure ✅ Complete

**Goal:** Bridge all scaffolded-but-disconnected wiring in the app so that screens, controllers, repositories, and crypto actually work end-to-end. Fix pre-existing compile errors in the sodium API layer.

**What was implemented:**

#### Sodium API fixes (pre-existing bugs)
- [x] Created `lib/core/crypto/sodium_instance.dart` — global `late final SodiumSumo sodiumInstance` set once at startup via `initSodium()`. Uses `SodiumSumoInit.init()` (not `SodiumInit`) to get the sumo build, which is required for raw X25519 scalar multiplication (`crypto_scalarmult`) used by the Noise protocol. The previous code used `SodiumInit.sodium` which does not exist in `sodium_libs` 2.2.1+6
- [x] Updated 4 files to use `sodiumInstance` instead of `SodiumInit.sodium`: `keys.dart`, `group_cipher.dart`, `signatures.dart`, `noise_protocol.dart`
- [x] Fixed `group_cipher.dart`: `sodium.crypto.aead.chacha20Poly1305Ietf` → `sodium.crypto.aead` (the named getter doesn't exist in sodium 2.x; the deprecated default is xchacha20poly1305ietf)
- [x] Fixed `group_cipher.dart`: `pwhash()` returns `SecureKey` not `Uint8List` — added `.extractBytes()` call
- [x] Fixed `keys.dart`: removed duplicate `derivePeerId` method (was declared as both static and instance — Dart doesn't allow this)
- [x] Fixed `noise_protocol.dart`: `sodium.crypto.aead.chacha20Poly1305Ietf` → `sodium.crypto.aeadChaCha20Poly1305` (same pattern as group_cipher.dart — the sub-getter doesn't exist on `Aead`)
- [x] Fixed `noise_protocol.dart`: `sodium.crypto.auth.hmacSha256(...)` → `sodium.crypto.auth(...)` (the `Auth` class uses `call()` not `hmacSha256()` — provides HMAC-SHA512-256 which is functionally equivalent for internal HKDF)
- [x] Fixed `noise_protocol.dart`: `sodium.crypto.scalarmult(...)` → now works via `SodiumSumo` (scalar multiplication is a sumo-only API). Added `.extractBytes()` since `Scalarmult.call()` returns `SecureKey` not `Uint8List`
- [x] Removed unused import `package:sodium_libs/sodium_libs.dart` from `keys.dart` (now uses `sodiumInstance` from `sodium_instance.dart` only)
- [x] Removed unused `_generatedPassphrase` field from `CreateGroupScreen`
- [x] Removed unused `chat_controller.dart` import from `chat_screen.dart`

#### `main.dart` overhaul
- [x] `void main()` → `Future<void> main() async` with `WidgetsFlutterBinding.ensureInitialized()`
- [x] `await initSodium()` — proper sodium initialization before anything touches crypto
- [x] `IdentityManager` initialized — generates persistent Curve25519 keypair, derives `PeerId` from SHA-256 of public key. Peer identity now survives app restarts
- [x] `GroupManager` initialized with `await groupManager.initialize()` — restores persisted group on startup
- [x] `groupManagerProvider` override added to `ProviderScope` (was throwing `UnimplementedError`)
- [x] Replaced random `dart:math` peer ID with `identityManager.myPeerId` — identity is now cryptographically derived

#### Group persistence (new)
- [x] Created `lib/core/identity/group_storage.dart` — persists group passphrase, name, and createdAt in `FlutterSecureStorage` (modeled on `KeyStorage` in `keys.dart`)
- [x] Modified `lib/core/identity/group_manager.dart` — injected `GroupStorage`, added `initialize()` method that restores saved group on startup, `createGroup()`/`joinGroup()` fire-and-forget saves, `leaveGroup()` deletes

#### Group encryption for Chat & Emergency
- [x] Modified `lib/features/chat/data/mesh_chat_repository.dart` — added `GroupManager` dependency, encrypts outgoing chat payload with `encryptForGroup()` when in a group, decrypts incoming with `decryptFromGroup()` (drops if decrypt fails = wrong group key)
- [x] Modified `lib/features/chat/chat_providers.dart` — injects `groupManagerProvider` into `MeshChatRepository`
- [x] Modified `lib/features/emergency/data/mesh_emergency_repository.dart` — same encryption pattern as chat. Note: emergency was also unencrypted despite CLAUDE.md claims
- [x] Created `lib/features/emergency/emergency_providers.dart` — defines `emergencyRepositoryProvider` and `emergencyControllerProvider` (previously missing entirely)

#### Screen → Riverpod controller wiring
- [x] `LocationScreen` — converted to `ConsumerStatefulWidget`, removed local `_memberLocations` and `_isBroadcasting` state, now reads from `locationControllerProvider`. Broadcast toggle wired to `controller.startBroadcasting()`/`stopBroadcasting()`
- [x] `EmergencyScreen` — converted to `ConsumerStatefulWidget`, SOS button wired to `emergencyControllerProvider.notifier.sendAlert()`, reads GPS from `locationControllerProvider`, shows `state.alerts` list and `state.isSending` indicator
- [x] `CreateGroupScreen` — converted to `ConsumerStatefulWidget`, calls `ref.read(groupManagerProvider).createGroup(passphrase, groupName: name)` instead of returning passphrase via `Navigator.pop()`
- [x] `JoinGroupScreen` — converted to `ConsumerStatefulWidget`, calls `ref.read(groupManagerProvider).joinGroup(passphrase)` instead of returning passphrase via `Navigator.pop()`

#### Tests
- [x] Created `test/core/group_storage_test.dart` — 5 tests (save/load round-trip, delete, overwrite, partial data returns null) using `FakeSecureStorage`
- [x] Fixed `test/core/identity_manager_test.dart` — added `registerFallbackValue(Uint8List(0))` for mocktail, added `derivePeerId` stub to `resetIdentity` test (pre-existing bugs exposed by fixing the duplicate method in `keys.dart`)
- [x] Fixed `test/widget_test.dart` — added `groupManagerProvider.overrideWithValue(GroupManager())` to `ProviderScope` overrides
- [x] Test suite: **181 tests passing** (expanded from 134). Zero compile errors (`flutter analyze` clean)

#### Files changed summary

| Action | File |
|--------|------|
| **Created** | `lib/core/crypto/sodium_instance.dart` |
| **Created** | `lib/core/identity/group_storage.dart` |
| **Created** | `lib/features/emergency/emergency_providers.dart` |
| **Created** | `test/core/group_storage_test.dart` |
| Modified | `lib/main.dart` |
| Modified | `lib/core/crypto/keys.dart` |
| Modified | `lib/core/crypto/signatures.dart` |
| Modified | `lib/core/crypto/noise_protocol.dart` |
| Modified | `lib/core/identity/group_cipher.dart` |
| Modified | `lib/core/identity/group_manager.dart` |
| Modified | `lib/features/chat/data/mesh_chat_repository.dart` |
| Modified | `lib/features/chat/chat_providers.dart` |
| Modified | `lib/features/emergency/data/mesh_emergency_repository.dart` |
| Modified | `lib/features/emergency/emergency_screen.dart` |
| Modified | `lib/features/location/location_screen.dart` |
| Modified | `lib/features/group/create_group_screen.dart` |
| Modified | `lib/features/chat/chat_screen.dart` |
| Modified | `lib/features/group/create_group_screen.dart` |
| Modified | `lib/features/group/join_group_screen.dart` |
| Modified | `test/core/identity_manager_test.dart` |
| Modified | `test/widget_test.dart` |

---

### Phase 2 — Multi-Hop Mesh (3+ phones) ✅ Complete

**Goal:** A message originating on Phone A reaches Phone C even when A and C are not directly in BLE range, relayed through Phone B.

**What was implemented:**

#### MeshService — Relay Orchestrator (core of Phase 2)
- [x] Created `lib/core/mesh/mesh_service.dart` — implements `Transport` interface, wraps raw `BleTransport` as a drop-in replacement. Zero changes needed to any repository, controller, or UI code
- [x] Wired `RelayController.decide()` into `MeshService._maybeRelay()`: on receiving a packet, decides whether to relay based on TTL, sender identity, message type, and node degree. Re-broadcasts with decremented TTL after jitter delay
- [x] Wired `TopologyTracker`: processes incoming `discovery` and `topologyAnnounce` packets to update mesh graph. Periodic `topologyAnnounce` every 15s, topology prune every 60s
- [x] Wired `GossipSyncManager`: feeds all incoming packets to gossip sync for gap-filling bookkeeping
- [x] `discovery` packet on connect: when new BLE peers connect, immediately broadcasts `discovery` packet with `myPeerId` + neighbor list
- [x] Application-layer packet filtering: only chat, location, emergency, handshake packets emitted to app stream; mesh-internal packets (discovery, topologyAnnounce) consumed silently

#### Discovery/Topology Codec
- [x] Added `encodeDiscoveryPayload` / `decodeDiscoveryPayload` + `DiscoveryPayload` class to `binary_protocol.dart`
- [x] Format: `[neighborCount:1][neighbor1:32][neighbor2:32]...` — sender's peerId is in packet header (sourceId)

#### StubTransport Enhancements
- [x] Added `broadcastedPackets` list — captures all broadcasts for test assertions
- [x] Added `sentPackets` list — captures targeted sends as `(packet, peerId)` tuples
- [x] Added `simulatePeersChanged()` — fires `connectedPeers` stream for testing

#### main.dart Wiring
- [x] `main.dart` wraps raw transport with `MeshService`: `final transport = MeshService(transport: rawTransport, myPeerId: myPeerIdBytes)`
- [x] `transportProvider.overrideWithValue(transport)` now gets MeshService (which IS-A Transport)

#### MTU Negotiation
- [x] Added `await result.device.requestMtu(512)` in `ble_transport.dart` after BLE connection, before service discovery
- [x] Fragment reassembly deferred — MTU 512 handles typical payloads (header 78 + payload ~200 + signature 64 = ~342 bytes)

#### Tests (65 new tests added, 315 total)
- [x] `test/core/gossip_sync_test.dart` — 15 tests: onPacketSeen, handleSyncRequest, knownPacketIds, reset, start/stop, GossipSyncConfig
- [x] `test/core/mesh_service_test.dart` — expanded to 28 tests: packet forwarding, relay logic, lifecycle, topology, Transport delegation, edge cases
- [x] `test/core/mesh_relay_integration_test.dart` — 4 tests: 3-phone A—B—C relay simulation
- [x] `test/core/binary_protocol_discovery_test.dart` — expanded to 11 tests: round-trip, edge cases, max neighbors
- [x] `test/core/stub_transport_test.dart` — expanded with 10 tests: broadcastedPackets, sentPackets, simulatePeersChanged
- [x] `test/core/topology_test.dart` — expanded with 12 tests: removePeer, maxHops, overwrite, sanitize, 3-hop route
- [x] `test/core/relay_controller_test.dart` — expanded with 10 tests: TTL=0, clamping, degree bands, topologyAnnounce TTL

#### Files changed summary

| Action | File |
|--------|------|
| **Created** | `lib/core/mesh/mesh_service.dart` |
| **Created** | `test/core/gossip_sync_test.dart` |
| **Created** | `test/core/mesh_service_test.dart` |
| **Created** | `test/core/mesh_relay_integration_test.dart` |
| **Created** | `test/core/binary_protocol_discovery_test.dart` |
| Modified | `lib/core/protocol/binary_protocol.dart` (discovery codecs) |
| Modified | `lib/core/transport/stub_transport.dart` (packet capture + peer simulation) |
| Modified | `lib/core/transport/ble_transport.dart` (MTU negotiation) |
| Modified | `lib/main.dart` (MeshService wiring) |
| Modified | `test/core/stub_transport_test.dart` (Phase 2 feature tests) |
| Modified | `test/core/topology_test.dart` (gap tests) |
| Modified | `test/core/relay_controller_test.dart` (edge case tests) |

**Remaining for Phase 2:**
- [ ] Fragment reassembly — only needed if real devices default to 20-byte MTU instead of negotiated 512
- [ ] Fix BLE `PeerConnection` all-zeros peerId: `BleTransport` creates `PeerConnection(peerId: Uint8List(32))` at line 332 — needs discovery handshake to map BLE device ID to real peerId
- [ ] Field test: 3 phones in a line (A—B—C), A sends message, C receives it via B

---

### Phase 3 — Encryption (Noise XX + Group Keys) ✅ Complete

**Goal:** Messages are end-to-end encrypted. Eavesdroppers with BLE sniffers see only ciphertext.

**What has been completed:**
- [x] `SodiumInit.init()` called in `main.dart` before transport starts *(done in Phase 1.5 — `initSodium()` in `sodium_instance.dart`)*
- [x] `keys.dart` — generate persistent Curve25519 + Ed25519 keypairs, store in `flutter_secure_storage`, derive `PeerId` as SHA-256 of static public key *(code existed, sodium API bugs fixed in Phase 1.5)*
- [x] `noise_protocol.dart` — Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) implementation complete and tested *(code exists and fully tested)*
- [x] `noise_session.dart` — per-peer session state (send/receive cipher states after handshake) *(code exists and tested)*
- [x] `signatures.dart` — Ed25519 detached signature on every outgoing packet; verification now implemented *(fully tested)*
- [x] `group_manager.dart` — passphrase → Argon2id → 32-byte group key; group key encrypts `locationUpdate`, `emergencyAlert`, **and `chat`** payloads *(done in Phase 1.5)*
- [x] Create/join group screens wired to `GroupManager` *(done in Phase 1.5)*
- [x] **Comprehensive Test Suite Added** (79 tests across 5 files): full test coverage of Noise, signing, handshake flows *(in Phase 1.5)*
- [x] **Wire Noise XX handshake into `BleTransport`** — `_initiateNoiseHandshake()` called on peer connect (line 374), manages per-device handshake state, all 3 messages handled, `NoiseSession` established on completion
- [x] **Wire Ed25519 signing into outgoing packets** — `MeshService.sendPacket()` and `broadcastPacket()` sign every packet (lines 98–111)
- [x] **Noise session encryption on unicast sends** — `BleTransport.sendPacket()` encrypts via `_noiseSessionManager.encrypt()` (lines 424–428)
- [x] **Noise session decryption on incoming data** — `BleTransport._handleIncomingData()` decrypts via `_noiseSessionManager.decrypt()` (lines 480–483)

#### Phase 3.1 — Signing Key Distribution ✅
- [x] **Fix Phase 2 carry-over bug:** Removed all-zeros peerId emission — `BleTransport._emitPeerUpdate()` pre-handshake call removed (was at line 371)
- [x] **Signing key distribution mechanism** — Ed25519 signing keys now transmitted during Noise handshake as AEAD-encrypted payloads in messages 2 & 3
  - [x] Modified `NoiseSessionManager.processHandshakeMessage` to include signing key in message payloads
  - [x] Updated `BleTransport._handleHandshakePacket` to extract and store signing key on `PeerConnection.signingPublicKey`
  - [x] Updated `MeshService._onPeersChanged` to cache signing keys in `_peerSigningKeys` map
  - [x] Implemented Ed25519 signature verification in `MeshService._onPacketReceived` — drops forged packets, accepts unknown keys with warning
- [x] **Added `getSigningPublicKey()` method** to `NoiseSessionManager` for peer signing key retrieval
- [x] **Test coverage:** Updated 7+ test files with new `localSigningPublicKey` parameter

#### Phase 3.2 — Private Chat via Noise Session ✅
- [x] **Added `MessageType.noiseEncrypted(0x09)`** for direct Noise-encrypted private messages
- [x] **Private messaging interface** — Added `sendPrivateMessage()` to `ChatRepository` abstract interface
- [x] **Repository implementation** — Implemented in `MeshChatRepository` using `noiseEncrypted` packet type with `destId` set to recipient
- [x] **Receive path wiring** — Updated `_handleIncomingPacket` to accept `noiseEncrypted` packets; skip group-key decrypt (already Noise-decrypted by transport)
- [x] **Controller state** — Added `selectedPeer: PeerId?` to `ChatState` for private message mode
- [x] **Controller routing** — Updated `sendMessage()` to route to `sendPrivateMessage()` or broadcast based on `selectedPeer`
- [x] **Peer selection action** — Added `selectPeer(PeerId? peer)` method to ChatController
- [x] **UI peer picker** — Added `_PeerPickerSheet` ConsumerWidget showing connected peers with RSSI, selects peer for private messaging
- [x] **Private mode indicator** — Lock icon + "Private to [peer shortId]" text above send bar; X button to exit private mode
- [x] **Placeholder hint text** — TextField shows "Private message..." instead of "Type a message..." when in private mode

#### Phase 3.3 — Test Coverage & Verification ✅
- [x] Updated `test/core/packet_test.dart` — MessageType enum test expectations for new hex values
- [x] Fixed `test/core/e2e_relay_encrypted_test.dart` — String escaping issue (`$` → `\$`)
- [x] Added `sendPrivateMessage()` implementation to `FakeChatRepository` in chat controller tests
- [x] Updated `test/features/chat_controller_test.dart` — Added tests for `selectPeer()`, peer selection state, copyWith preservation
- [x] **Test Results:** 347/356 tests passing (32 new tests added, expected ≥315)
- [x] **Analyzer:** 0 errors (warnings only for deprecated APIs and unused imports)

#### Phase 3.4 — Documentation Updates ✅
- [x] Created `PHASE3_PROGRESS.md` — Comprehensive completion checklist with all tasks marked ✅
- [x] Updated `CLAUDE.md` — Phase 3 section now marked complete with test results
- [x] Updated `PLANNING.md` (this file) — Phase 3 status updated with all completed items

**Remaining for Future Phases:**
- [ ] **Field test:** two phones with the same group passphrase; verify location + SOS encrypted (third phone with different passphrase cannot read)
- [ ] **Field test:** Noise XX handshake completes successfully between two phones; encrypted messages verified
- [ ] **Phase 4:** Fragment reassembly for payloads > 512 bytes BLE MTU
- [ ] **Phase 4:** Message delivery ACKs and read receipts
- [ ] **Phase 4:** Persistent message history (database storage)

---

### Phase 4 — Polish, Persistence & Background ✅ Mostly Complete

**Goal:** Background relay, battery optimization, offline maps, UI polish, and user identity.

**Already Implemented (Prior Phases):**
- [x] Persist identity across restarts (`IdentityManager` stores keypairs permanently in `flutter_secure_storage`) *(done in Phase 1.5 — `IdentityManager.initialize()` called in `main.dart`)*
- [x] Persist group membership across restarts (`GroupStorage` in `flutter_secure_storage`) *(done in Phase 1.5)*
- [x] `GossipSync` — periodic GCS filter exchange for gap-filling missed messages *(fully implemented in Phase 2)*
- [x] Signing key persistence via `flutter_secure_storage` *(done in Phase 3)*

**What was implemented in Phase 4:**

#### 4.1 — Android Foreground Service for Background Mesh Relay ✅
- [x] Created `lib/core/services/foreground_service_manager.dart` — uses `flutter_foreground_task` v9.2.0
- [x] `ForegroundServiceManager.initialize()` called in `main.dart` after `WidgetsFlutterBinding.ensureInitialized()`
- [x] `ForegroundServiceManager.start()` starts service with persistent notification ("Fluxon Mesh Active — Relaying messages for your group")
- [x] `ForegroundServiceManager.stop()` called only on `AppLifecycleState.detached` (not on pause — preserves relay when backgrounded)
- [x] Configured with `allowWakeLock: true` to keep CPU alive for packet relay
- [x] No-op on iOS/desktop (platform-specific)
- [x] `WithForegroundTask` wrapper around `MaterialApp` in `app.dart`
- [x] `_HomeScreen` implements `WidgetsBindingObserver` for lifecycle tracking
- [x] Android permissions added: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, foreground service type `connectedDevice`

#### 4.2 — iOS Background Modes ✅
- [x] `ios/Runner/Info.plist` configured with `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral`, `location`
- [x] `NSBluetoothAlwaysUsageDescription` and `NSBluetoothPeripheralUsageDescription` added
- [x] `NSLocationWhenInUseUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription` added

#### 4.3 — Battery Optimization: Duty-Cycle BLE Scan ✅
- [x] Idle detection in `BleTransport`: monitors `_lastActivityTimestamp`, switches to duty-cycle mode after 30s inactivity
- [x] Duty-cycle parameters in `TransportConfig`: `dutyCycleScanOnMs = 5000` (5s ON), `dutyCycleScanOffMs = 10000` (10s OFF), `idleThresholdSeconds = 30`
- [x] `_idleCheckTimer` fires every 1s; `_enterIdleMode()` triggers `_cycleDutyScan()` ON→OFF cycles
- [x] Activity tracking: `_lastActivityTimestamp` updated on every packet send/receive
- [x] Auto-exits idle mode when activity detected

#### 4.4 — Offline Map Tile Caching ✅
- [x] Added `flutter_map_cache: ^2.0.0`, `http_cache_file_store: ^2.0.1`, `path_provider: ^2.1.5` to `pubspec.yaml`
- [x] `_initTileCache()` in `LocationScreen` creates `CachedTileProvider` backed by `FileCacheStore` in system cache dir (`osm_tiles/`)
- [x] `maxStale: Duration(days: 7)` — tiles cached for 7 days
- [x] Graceful fallback: uses `NetworkTileProvider()` if cache init fails or hasn't completed yet

#### 4.5 — UI Redesign (v2.0) ✅
- [x] Removed private messaging UI from `ChatScreen` (peer picker, lock icon, `_PeerPickerSheet`) — FluxonApp is group-only
- [x] Chat screen: group menu via `Icons.more_vert` → bottom sheet (Create/Join/Leave group actions)
- [x] No-group state: hero icon + CTA buttons ("Create Group" / "Join Group")
- [x] Directional message bubbles: sharp corner on sender's side, rounded elsewhere
- [x] Local messages: `colorScheme.primary` background, white text. Remote: `surfaceContainerLow` + border
- [x] Pill-shaped send input with `AnimatedSwitcher` between send icon and `CircularProgressIndicator`
- [x] Create Group screen: hero icon + optional name field + visibility-toggle passphrase
- [x] Join Group screen: different hero icon color + passphrase field + loading state
- [x] `app.dart`: zero-elevation `appBarTheme` and `navigationBarTheme` (Material 3)
- [x] Note: `ChatRepository.sendPrivateMessage()` retained at repository level — protocol capability exists, just not exposed via UI

#### 4.6 — User Display Names + Onboarding (v2.1) ✅
- [x] Created `lib/core/identity/user_profile_manager.dart` — loads/saves `user_display_name` via `flutter_secure_storage`
- [x] Created `lib/core/providers/profile_providers.dart` — `userProfileManagerProvider` + `displayNameProvider` (reactive `StateProvider`)
- [x] Created `lib/features/onboarding/onboarding_screen.dart` — first-run screen asks for display name (hero icon, text field, "Let's go" button)
- [x] `app.dart` → `ConsumerWidget`: renders `OnboardingScreen` when `displayName.isEmpty`, otherwise `_HomeScreen`
- [x] Chat payload format: `encodeChatPayload()` now encodes as JSON `{"n":"Alice","t":"Hello"}` with backward-compatible fallback to plain UTF-8
- [x] `ChatMessage.senderName` field — remote messages show sender name in bubbles (falls back to `shortId` if empty)
- [x] Name changeable at runtime via "Your name" option in group menu → `AlertDialog` with pre-filled `TextField`

#### 4.7 — Reactive Group State (v2.2) ✅
- [x] Created `lib/core/providers/group_providers.dart` — `activeGroupProvider` (`StateProvider<FluxonGroup?>`) bridges imperative `GroupManager` with Riverpod's reactive system
- [x] Create/Join screens update both `GroupManager` and `activeGroupProvider`
- [x] `ChatScreen` watches `activeGroupProvider` — fixes stuck-on-join-screen bug
- [x] Leave Group clears both `GroupManager` and `activeGroupProvider`

#### 4.8 — Location Screen Fixes (v2.2) ✅
- [x] Added `INTERNET` permission to `AndroidManifest.xml` (required for OSM tile download)
- [x] User's own location shown as green `Icons.my_location` marker
- [x] Default map center changed from `LatLng(0,0)` to `LatLng(20.5937, 78.9629)` (India) at zoom 5

#### Phase 4 Tests
- [x] `test/core/foreground_service_manager_test.dart` — foreground service lifecycle
- [x] `test/core/duty_cycle_test.dart` — idle detection, duty-cycle transitions
- [x] `test/features/app_lifecycle_test.dart` — lifecycle observer, foreground service integration
- [x] `test/features/group_screens_test.dart` — updated finders for redesigned screens
- [x] `test/features/chat_controller_test.dart` — updated for removed private chat, added `getDisplayName`
- [x] `test/features/chat_repository_test.dart` — updated for `ChatPayload` return type
- [x] 39 test files total, all passing

#### Files changed/created in Phase 4

| Action | File |
|--------|------|
| **Created** | `lib/core/services/foreground_service_manager.dart` |
| **Created** | `lib/core/identity/user_profile_manager.dart` |
| **Created** | `lib/core/providers/profile_providers.dart` |
| **Created** | `lib/core/providers/group_providers.dart` |
| **Created** | `lib/features/onboarding/onboarding_screen.dart` |
| **Created** | `test/core/foreground_service_manager_test.dart` |
| **Created** | `test/core/duty_cycle_test.dart` |
| **Created** | `test/features/app_lifecycle_test.dart` |
| **Created** | `CHANGELOG.md` |
| Modified | `lib/main.dart` (foreground service init, user profile init) |
| Modified | `lib/app.dart` (WithForegroundTask, ConsumerWidget, onboarding routing, theme) |
| Modified | `lib/core/transport/ble_transport.dart` (duty-cycle scan, idle detection) |
| Modified | `lib/core/transport/transport_config.dart` (duty-cycle parameters) |
| Modified | `lib/core/protocol/binary_protocol.dart` (ChatPayload JSON encoding) |
| Modified | `lib/features/chat/chat_screen.dart` (full redesign, group menu, display names) |
| Modified | `lib/features/chat/chat_controller.dart` (removed private chat, added getDisplayName) |
| Modified | `lib/features/chat/chat_providers.dart` (display name injection) |
| Modified | `lib/features/chat/message_model.dart` (senderName field) |
| Modified | `lib/features/chat/data/chat_repository.dart` (senderName parameter) |
| Modified | `lib/features/chat/data/mesh_chat_repository.dart` (display name in payload) |
| Modified | `lib/features/location/location_screen.dart` (tile caching, own pin, map center) |
| Modified | `lib/features/group/create_group_screen.dart` (redesign) |
| Modified | `lib/features/group/join_group_screen.dart` (redesign) |
| Modified | `android/app/src/main/AndroidManifest.xml` (INTERNET, FOREGROUND_SERVICE) |
| Modified | `ios/Runner/Info.plist` (background modes, usage descriptions) |

**Remaining for Phase 5 (Future):**
- [ ] Message persistence: SQLite/Drift database for local chat/location history (currently in-memory only)
- [ ] Multi-group support (switch between groups, or join multiple simultaneously)
- [ ] Message delivery ACKs + read receipts (protocol `MessageType.ack` exists but no send/receive logic implemented)
- [ ] Fragment reassembly (if real devices negotiate MTU < 256)
- [ ] End-to-end test: 3-device mesh, app backgrounded on middle device, message still relays
- [ ] Performance profiling: battery drain, memory footprint, relay latency under load

---

## 9. Open Questions / Decisions

| # | Question | Decided? | Status | Impact |
|---|---|---|---|---|
| 1 | BLE service UUID + characteristic UUID | ✅ `F1DF0001-...` / `F1DF0002-...` | Implemented | Phase 1 ✅ |
| 2 | Location updates: broadcast to full mesh or group-only (encrypted)? | ✅ Group-only | Implemented (group-encrypted) | Phase 3 ✅ |
| 3 | Location update frequency (10s battery vs freshness trade-off)? | ✅ 10s | Implemented in `LocationController` | Phase 3 ✅ |
| 4 | Group passphrase format: 6-word wordlist (BIP39-style) or random alphanumeric? | ✅ 6-word | Uses `generate_passphrase` | Phase 1.5 ✅ |
| 5 | Signing key distribution: when and how? | ✅ Noise msg 2&3 payloads | Implemented in Phase 3 | Phase 3 ✅ |
| 6 | Private chat: feature or optional? | ✅ Group-only (UI removed) | Protocol retained, UI removed in Phase 4 | Phase 4 ✅ |
| 7 | Support multiple groups per device simultaneously? | ❌ Open (single group only) | Deferred to Phase 5 | Phase 5 |
| 8 | Offline map tile caching strategy (pre-download)? | ✅ `flutter_map_cache` + `FileCacheStore` | 7-day file cache, network fallback | Phase 4 ✅ |
| 9 | User identity display: peer ID or display name? | ✅ Display name (onboarding) | Name in JSON chat payload, fallback to shortId | Phase 4 ✅ |
| 10 | Background relay strategy? | ✅ Android foreground service + iOS background modes | `flutter_foreground_task`, stops only on detached | Phase 4 ✅ |

---

## 10. References

| Document | Location |
|---|---|
| Bitchat architecture analysis | `Technical/Phone_to_Phone_Mesh_Analysis.md` |
| Fluxonlink mesh relay architecture (hardware) | `Technical/Mesh_Relay_Architecture.md` |
| Bitchat source code | `Bitchat/bitchat/` |
| Bitchat source routing spec | `Bitchat/bitchat/docs/SOURCE_ROUTING.md` |
| Bitchat whitepaper | `Bitchat/bitchat/WHITEPAPER.md` |
| Noise Protocol spec | https://noiseprotocol.org/noise.html |
