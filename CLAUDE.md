# CLAUDE.md — FluxonApp

## What is FluxonApp?

FluxonApp is a Flutter mobile app for **off-grid, BLE mesh networking**. It enables phone-to-phone group chat, real-time location sharing, and emergency SOS alerts — all peer-to-peer without internet. Adapted from the Bitchat protocol with Fluxonlink-specific additions.

**Current status:** Phase 4 complete. 39 test files, all passing. Zero compile errors.

## Tech Stack

- **Flutter** (Dart SDK ^3.10.8) — cross-platform mobile
- **flutter_blue_plus** — BLE central role (scanning, GATT connections)
- **ble_peripheral** — BLE peripheral role (advertising, GATT server). Two packages needed for dual-role BLE.
- **sodium_libs** — libsodium sumo bindings via `SodiumSumoInit` (X25519, ChaCha20-Poly1305, Ed25519, Argon2id, BLAKE2b)
- **flutter_riverpod** — state management and dependency injection
- **geolocator** — GPS access
- **permission_handler** — runtime permission requests (BLE, location)
- **flutter_map + latlong2** — OpenStreetMap rendering
- **flutter_map_cache + http_cache_file_store** — offline tile caching (7-day file cache)
- **path_provider** — system cache directory for tile storage
- **flutter_secure_storage** — encrypted key, group, and profile persistence
- **flutter_foreground_task** — Android foreground service for background BLE relay
- **archive** — compression (declared but not yet actively used)

## Project Structure

```
lib/
  main.dart                         # Entry point — inits sodium, identity, profile, transport, foreground service, ProviderScope overrides
  app.dart                          # ConsumerWidget MaterialApp, bottom nav (Chat/Map/SOS), onboarding routing, named routes
  core/
    transport/                      # BLE hardware abstraction
      transport.dart                #   Abstract Transport interface
      transport_config.dart         #   Tunable constants (TTL, intervals, limits, duty-cycle config)
      ble_transport.dart            #   Concrete BLE implementation (central + peripheral + duty-cycle scan)
      stub_transport.dart           #   Full-featured test double (loopback, packet capture, peer simulation)
    mesh/                           # Mesh network logic
      mesh_service.dart             #   Multi-hop relay orchestrator (wraps Transport, applies relay/dedup/topology)
      relay_controller.dart         #   Flood control / relay decisions
      topology_tracker.dart         #   Graph tracking, BFS routing
      deduplicator.dart             #   LRU + time-based packet dedup
      gossip_sync.dart              #   Anti-entropy gap-filling
    crypto/                         # Cryptography
      sodium_instance.dart          #   Global SodiumSumo singleton, initSodium() called once in main()
      noise_protocol.dart           #   Noise XX handshake (full impl)
      noise_session.dart            #   Post-handshake encrypted session
      noise_session_manager.dart    #   Manages Noise XX state machines keyed by BLE device ID
      signatures.dart               #   Ed25519 packet signing
      keys.dart                     #   Key generation, storage, management
    identity/                       # Identity and groups
      peer_id.dart                  #   32-byte peer identity (SHA-256 of pubkey)
      identity_manager.dart         #   Local identity + peer trust
      group_cipher.dart             #   Group symmetric encryption (ChaCha20)
      group_manager.dart            #   Group lifecycle (create/join/leave)
      group_storage.dart            #   Persistent group membership via flutter_secure_storage
      user_profile_manager.dart     #   User display name persistence via flutter_secure_storage
    device/                         # Hardware abstractions
      device_services.dart          #   GpsService / PermissionService interfaces
    services/                       # Platform services
      foreground_service_manager.dart #   Android foreground service for background BLE relay
    protocol/                       # Wire format
      message_types.dart            #   Enum of all packet types (0x01–0x0E)
      packet.dart                   #   FluxonPacket encode/decode
      binary_protocol.dart          #   Payload codecs (chat with JSON senderName, location, emergency, discovery)
      padding.dart                  #   PKCS#7 padding
    providers/                      # Shared Riverpod providers
      group_providers.dart          #   groupManagerProvider + activeGroupProvider (reactive group state bridge)
      profile_providers.dart        #   userProfileManagerProvider + displayNameProvider
  shared/                           # Pure utilities
    hex_utils.dart                  #   Hex encode/decode
    logger.dart                     #   SecureLogger (no PII)
    compression.dart                #   zlib compress/decompress
    geo_math.dart                   #   Haversine distance
  features/                         # Feature modules (Clean Architecture slices)
    onboarding/
      onboarding_screen.dart        #   First-run display name entry screen
    chat/
      chat_screen.dart              #   Group chat UI (group menu, directional bubbles, display names)
      chat_controller.dart          #   StateNotifier<ChatState> (group broadcast only)
      chat_providers.dart           #   Riverpod providers (incl. shared infra: transportProvider, myPeerIdProvider, display name)
      message_model.dart            #   ChatMessage data class (includes senderName field)
      data/
        chat_repository.dart        #   Abstract interface (includes sendPrivateMessage for protocol-level support)
        mesh_chat_repository.dart   #   Concrete mesh implementation (group + Noise-encrypted)
    location/
      location_screen.dart          #   Map UI (flutter_map + OSM + offline tile caching + own location pin)
      location_controller.dart      #   StateNotifier<LocationState>
      location_providers.dart       #   Riverpod providers
      location_model.dart           #   LocationUpdate data class
      data/
        location_repository.dart    #   Abstract interface
        mesh_location_repository.dart # Concrete mesh + group encryption
    emergency/
      emergency_screen.dart         #   SOS trigger UI (long-press confirm)
      emergency_controller.dart     #   StateNotifier<EmergencyState>
      emergency_providers.dart      #   Riverpod providers for emergency feature
      data/
        emergency_repository.dart   #   Abstract interface
        mesh_emergency_repository.dart # Concrete mesh + 3x rebroadcast
    group/
      create_group_screen.dart      #   Group creation UI (hero icon, passphrase visibility toggle)
      join_group_screen.dart        #   Group join UI (hero icon, loading state)
test/
  core/                             # 26 test files: mesh, crypto, protocol, transport, services
  features/                         # 11 test files: controllers, repositories, screens, lifecycle
  shared/                           # Utility tests (geo_math)
  widget_test.dart                  # Root widget smoke test
  integration_test/                 # On-device crypto validation
```

## Architecture Patterns

### Clean Architecture per Feature
Each feature follows: `Screen -> Controller (StateNotifier) -> Repository (abstract) -> MeshRepository (concrete)`. Controllers never import Transport, BinaryProtocol, or crypto directly.

### Dependency Inversion (DIP)
Every external dependency is behind an abstract interface:
- `Transport` (abstract) <- `BleTransport` (BLE) / `StubTransport` (tests & desktop)
- `Transport` (abstract) <- `MeshService` (wraps raw transport with multi-hop relay)
- `ChatRepository` <- `MeshChatRepository`
- `LocationRepository` <- `MeshLocationRepository`
- `EmergencyRepository` <- `MeshEmergencyRepository`
- `GpsService` <- `GeolocatorGpsService`
- `PermissionService` <- `GeolocatorPermissionService`

### Riverpod DI
Infrastructure providers (`transportProvider`, `myPeerIdProvider`) are defined in `chat_providers.dart` and `groupManagerProvider` in `core/providers/group_providers.dart` — all with `throw UnimplementedError()`. They **must** be overridden via `ProviderScope` overrides at the app root (`main.dart` does this).

Additional providers added in Phase 4:
- `activeGroupProvider` — `StateProvider<FluxonGroup?>` that bridges imperative `GroupManager` mutations with Riverpod's reactive system
- `userProfileManagerProvider` + `displayNameProvider` — reactive user display name state

### Dual Cryptography Layers
1. **Session layer**: Noise XX (X25519 + ChaCha20-Poly1305 + SHA256) per peer-pair
2. **Group layer**: Argon2id-derived symmetric key (ChaCha20-Poly1305) shared via passphrase
3. **Packet auth**: Ed25519 detached signatures on every packet (signing keys distributed via Noise handshake messages 2 & 3)

### Stream-Based Reactive Data Flow
`BleTransport` -> `MeshService` (relay/dedup/topology filtering) -> `Stream<FluxonPacket>` -> Repositories filter by MessageType -> Controllers subscribe and update StateNotifier state -> UI rebuilds via Riverpod.

## Startup Sequence (main.dart)

1. `WidgetsFlutterBinding.ensureInitialized()`
2. `await initSodium()` — initializes global `SodiumSumo` instance
3. `ForegroundServiceManager.initialize()` — configures Android foreground service
4. `IdentityManager` — generates/loads persistent Curve25519 keypair, derives `PeerId`
5. `UserProfileManager` — loads persisted display name from secure storage
6. `GroupManager` + `await groupManager.initialize()` — restores persisted group from secure storage
7. Platform-conditional transport: `BleTransport` on Android/iOS, `StubTransport` on desktop
8. Raw transport wrapped with `MeshService` for multi-hop relay
9. `ProviderScope` overrides: `transportProvider`, `myPeerIdProvider`, `groupManagerProvider`, `userProfileManagerProvider`, `displayNameProvider`
10. BLE starts after first frame via `addPostFrameCallback` (avoids startup freeze on permission dialogs)
11. Foreground service starts on app resume, stops only on `AppLifecycleState.detached`

## App Routing

- `FluxonApp` (`app.dart`) is a `ConsumerWidget` that watches `displayNameProvider`
- If display name is empty → renders `OnboardingScreen` (first-run name entry)
- Otherwise → renders `_HomeScreen` with bottom nav (Chat / Map / SOS)
- Named routes: `/create-group`, `/join-group`

## Wire Protocol

Binary packet format (big-endian):
```
[version:1][type:1][ttl:1][flags:1][timestamp:8][sourceId:32][destId:32][payloadLen:2][payload:N][signature:64]
```
- Header: 78 bytes, signature: 64 bytes
- Max TTL: 7, max payload: 512 bytes
- Broadcast = destId all zeros
- Packet ID (dedup key) = `sourceId:timestamp:type`

### Chat Payload Format
- JSON encoding when senderName is present: `{"n":"Alice","t":"Hello"}`
- Plain UTF-8 fallback for legacy/empty names
- Detection via `{"n":` prefix for backward compatibility

### Message Types (0x01–0x0E)

| Value | Name | Origin | Description |
|---|---|---|---|
| 0x01 | handshake | Bitchat | Noise XX handshake |
| 0x02 | chat | Bitchat | Group chat (group-encrypted) |
| 0x03 | topologyAnnounce | Bitchat | Mesh topology link-state |
| 0x04 | gossipSync | Bitchat | GCS gossip sync request |
| 0x05 | ack | Bitchat | Acknowledgement |
| 0x06 | ping | Bitchat | Keepalive |
| 0x07 | pong | Bitchat | Keepalive response |
| 0x08 | discovery | Bitchat | Peer discovery broadcast |
| 0x09 | noiseEncrypted | Bitchat | Direct Noise-encrypted message (private, protocol only — no UI) |
| 0x0A | locationUpdate | Fluxonlink | GPS coordinate broadcast (group-encrypted) |
| 0x0B | groupJoin | Fluxonlink | Group join request |
| 0x0C | groupJoinResponse | Fluxonlink | Group join response |
| 0x0D | groupKeyRotation | Fluxonlink | Group key rotation |
| 0x0E | emergencyAlert | Fluxonlink | SOS broadcast (group-encrypted) |

## Build & Run

```bash
flutter pub get
flutter run                    # Run on connected device/emulator
flutter test                   # Run all unit tests (~347 tests across 39 files)
flutter test test/core/        # Run core tests only
flutter test test/features/    # Run feature tests only
```

## Key Constants (TransportConfig)

| Parameter | Default | Notes |
|---|---|---|
| Max TTL | 7 | Hop limit for flood routing |
| Max central links | 6 | iOS BLE limit |
| Fragment size | 469 bytes | ~512 MTU minus overhead |
| Dedup cache | 1000 entries / 300s | Packet deduplication |
| Location broadcast | 10s | GPS share interval |
| Emergency rebroadcast | 3x / 500ms | SOS reliability |
| BLE scan interval | 2000ms | Discovery cadence |
| Topology freshness | configurable | Pruning timer for stale topology entries |
| Duty-cycle scan ON | 5000ms | BLE scan ON duration when idle |
| Duty-cycle scan OFF | 10000ms | BLE scan OFF duration when idle |
| Idle threshold | 30s | Time without activity before entering duty-cycle mode |

## BLE UUIDs

- **Service UUID**: `F1DF0001-1234-5678-9ABC-DEF012345678`
- **Characteristic UUID**: `F1DF0002-1234-5678-9ABC-DEF012345678`

## Platform Configuration

### Android (`AndroidManifest.xml`)
- `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (API 31+)
- `ACCESS_FINE_LOCATION` (required for BLE scan)
- `INTERNET` (required for OSM tile download)
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` (background BLE relay)

### iOS (`Info.plist`)
- `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral`, `location`
- `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`
- `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`

## Phase Completion Status

| Phase | What | Status |
|---|---|---|
| Phase 1 | BLE chat between two phones | ✅ Complete |
| Phase 1.5 | Sodium API fixes, group infrastructure, main.dart overhaul | ✅ Complete |
| Phase 2 | Multi-hop mesh (MeshService, relay, topology) | ✅ Complete |
| Phase 3 | Noise XX encryption, signing key distribution, private chat protocol | ✅ Complete |
| Phase 4 | Background relay, duty-cycle BLE, offline maps, UI redesign, user names, onboarding | ✅ Complete |

## Known TODOs / Future Work (Phase 5+)

- Message persistence: SQLite/Drift database for local chat/location history (currently in-memory only)
- Multi-group support (switch between groups, or join multiple simultaneously)
- Message delivery ACKs + read receipts (protocol `MessageType.ack` exists but no send/receive logic)
- Fragment reassembly for payloads exceeding BLE MTU (if real devices negotiate MTU < 256)
- End-to-end field test: 3-device mesh, app backgrounded on middle device, message still relays
- Performance profiling: battery drain, memory footprint, relay latency under load
- Shared infra providers (`transportProvider`, `myPeerIdProvider`) still live in `chat_providers.dart` — ideally should move to `core/providers/` (refactoring, not blocking)

## Conventions

- **Immutable state**: Controllers use `copyWith` pattern on state classes
- **SRP extraction**: Utility logic is extracted into dedicated classes (e.g., `GeoMath` from `LocationUpdate`, `GroupCipher` from `GroupManager`)
- **No PII logging**: `SecureLogger` is used throughout — never log keys, peer IDs, or locations
- **Packet types**: Defined in `MessageType` enum (0x01–0x0E)
- **Tests**: Mirror the `lib/` structure under `test/`; use abstract interfaces for mocking
- **Platform-conditional transport**: `BleTransport` on mobile, `StubTransport` on desktop/test
- **Group-only UI**: Private chat protocol exists at repository level (`sendPrivateMessage`) but UI was removed in Phase 4 — FluxonApp is group-focused
- **Reactive group state**: Create/Join/Leave group actions update both `GroupManager` (imperative) and `activeGroupProvider` (Riverpod reactive)
- **Display names**: Transmitted in JSON chat payload `{"n":"name","t":"text"}`, with plain UTF-8 fallback
