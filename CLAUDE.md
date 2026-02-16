# CLAUDE.md — FluxonApp

## What is FluxonApp?

FluxonApp is a Flutter mobile app for **off-grid, BLE mesh networking**. It enables phone-to-phone group chat, real-time location sharing, and emergency SOS alerts — all peer-to-peer without internet. Adapted from the Bitchat protocol with Fluxonlink-specific additions.

## Tech Stack

- **Flutter** (Dart SDK ^3.10.8) — cross-platform mobile
- **flutter_blue_plus** — BLE central role (scanning, GATT connections)
- **ble_peripheral** — BLE peripheral role (advertising, GATT server). Two packages needed for dual-role BLE.
- **sodium_libs** — libsodium sumo bindings via `SodiumSumoInit` (X25519, ChaCha20-Poly1305, Ed25519, Argon2id, BLAKE2b)
- **flutter_riverpod** — state management and dependency injection
- **geolocator** — GPS access
- **permission_handler** — runtime permission requests (BLE, location)
- **flutter_map + latlong2** — OpenStreetMap rendering
- **flutter_secure_storage** — encrypted key and group persistence
- **archive** — compression (declared but not yet actively used)

## Project Structure

```
lib/
  main.dart                         # Entry point — inits sodium, identity, transport, ProviderScope overrides
  app.dart                          # MaterialApp, bottom nav (Chat/Map/SOS), named routes for group screens
  core/
    transport/                      # BLE hardware abstraction
      transport.dart                #   Abstract Transport interface
      transport_config.dart         #   Tunable constants (TTL, intervals, limits, topologyFreshness)
      ble_transport.dart            #   Concrete BLE implementation (central + peripheral)
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
    device/                         # Hardware abstractions
      device_services.dart          #   GpsService / PermissionService interfaces
    protocol/                       # Wire format
      message_types.dart            #   Enum of all packet types (0x01–0x0D)
      packet.dart                   #   FluxonPacket encode/decode
      binary_protocol.dart          #   Payload codecs (chat, location, emergency, discovery)
      padding.dart                  #   PKCS#7 padding
    providers/                      # Shared Riverpod providers
      group_providers.dart          #   groupManagerProvider (must be overridden at app root)
  shared/                           # Pure utilities
    hex_utils.dart                  #   Hex encode/decode
    logger.dart                     #   SecureLogger (no PII)
    compression.dart                #   zlib compress/decompress
    geo_math.dart                   #   Haversine distance
  features/                         # Feature modules (Clean Architecture slices)
    chat/
      chat_screen.dart              #   Chat UI
      chat_controller.dart          #   StateNotifier<ChatState>
      chat_providers.dart           #   Riverpod providers (incl. shared infra: transportProvider, myPeerIdProvider)
      message_model.dart            #   ChatMessage data class
      data/
        chat_repository.dart        #   Abstract interface
        mesh_chat_repository.dart   #   Concrete mesh implementation
    location/
      location_screen.dart          #   Map UI (flutter_map + OSM)
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
      create_group_screen.dart      #   Group creation UI
      join_group_screen.dart        #   Group join UI
test/
  core/                             # ~20 test files: mesh, crypto, protocol, transport
  features/                         # ~9 test files: controllers, repositories, screens
  shared/                           # Utility tests (geo_math)
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

### Dual Cryptography Layers
1. **Session layer**: Noise XX (X25519 + ChaCha20-Poly1305 + SHA256) per peer-pair
2. **Group layer**: Argon2id-derived symmetric key (ChaCha20-Poly1305) shared via passphrase
3. **Packet auth**: Ed25519 detached signatures on every packet

### Stream-Based Reactive Data Flow
`BleTransport` -> `MeshService` (relay/dedup/topology filtering) -> `Stream<FluxonPacket>` -> Repositories filter by MessageType -> Controllers subscribe and update StateNotifier state -> UI rebuilds via Riverpod.

## Startup Sequence (main.dart)

1. `WidgetsFlutterBinding.ensureInitialized()`
2. `await initSodium()` — initializes global `SodiumSumo` instance
3. `IdentityManager` — generates/loads persistent Curve25519 keypair, derives `PeerId`
4. `GroupManager` + `await groupManager.initialize()` — restores persisted group from secure storage
5. Platform-conditional transport: `BleTransport` on Android/iOS, `StubTransport` on desktop
6. Raw transport wrapped with `MeshService` for multi-hop relay
7. `ProviderScope` overrides: `transportProvider`, `myPeerIdProvider`, `groupManagerProvider`
8. BLE starts after first frame via `addPostFrameCallback` (avoids startup freeze on permission dialogs)

## Wire Protocol

Binary packet format (big-endian):
```
[version:1][type:1][ttl:1][flags:1][timestamp:8][sourceId:32][destId:32][payloadLen:2][payload:N][signature:64]
```
- Header: 78 bytes, signature: 64 bytes
- Max TTL: 7, max payload: 512 bytes
- Broadcast = destId all zeros
- Packet ID (dedup key) = `sourceId:timestamp:type`

## Build & Run

```bash
flutter pub get
flutter run                    # Run on connected device/emulator
flutter test                   # Run all unit tests
flutter test test/core/        # Run core tests only
flutter test test/features/    # Run feature tests only
```

## Key Constants (TransportConfig)

| Parameter | Default | Notes |
|---|---|---|
| Max TTL | 7 | Hop limit for flood routing |
| Max connections | 7 | BLE peer limit |
| Dedup cache | 1024 entries / 300s | Packet deduplication |
| Location broadcast | 10s | GPS share interval |
| Emergency rebroadcast | 3x / 500ms | SOS reliability |
| BLE scan interval | 2000ms | Discovery cadence |
| Topology freshness | configurable | Pruning timer for stale topology entries |

## BLE UUIDs

- **Service UUID**: `F1DF0001-1234-5678-9ABC-DEF012345678`
- **Characteristic UUID**: `F1DF0002-1234-5678-9ABC-DEF012345678`

## Known TODOs / Incomplete Wiring

- Noise XX handshake not yet wired into `BleTransport` — `NoiseSessionManager` exists but isn't called on BLE connect/disconnect
- Ed25519 signature verification on incoming packets is deferred (`MeshService` logs "verification deferred (key unknown)")
- `BleTransport` creates `PeerConnection` with all-zeros peerId (needs discovery handshake to map BLE device ID to real peerId)
- Fragment reassembly for payloads exceeding BLE MTU not yet implemented
- Shared infra providers (`transportProvider`, `myPeerIdProvider`) still live in `chat_providers.dart` — ideally should move to `core/providers/`

## Conventions

- **Immutable state**: Controllers use `copyWith` pattern on state classes
- **SRP extraction**: Utility logic is extracted into dedicated classes (e.g., `GeoMath` from `LocationUpdate`, `GroupCipher` from `GroupManager`)
- **No PII logging**: `SecureLogger` is used throughout — never log keys, peer IDs, or locations
- **Packet types**: Defined in `MessageType` enum (0x01–0x0D)
- **Tests**: Mirror the `lib/` structure under `test/`; use abstract interfaces for mocking
- **Platform-conditional transport**: `BleTransport` on mobile, `StubTransport` on desktop/test
