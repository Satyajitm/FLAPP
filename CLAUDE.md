# CLAUDE.md — FluxonApp

## What is FluxonApp?

FluxonApp is a Flutter mobile app for **off-grid, BLE mesh networking**. It enables phone-to-phone group chat, real-time location sharing, and emergency SOS alerts — all peer-to-peer without internet. Adapted from the Bitchat protocol with Fluxonlink-specific additions.

## Tech Stack

- **Flutter** (Dart SDK ^3.10.8) — cross-platform mobile
- **flutter_blue_plus** — BLE scanning, advertising, GATT connections
- **sodium_libs** — libsodium bindings (X25519, ChaCha20-Poly1305, Ed25519, Argon2id, BLAKE2b)
- **flutter_riverpod** — state management and dependency injection
- **geolocator** — GPS access and permissions
- **flutter_map + latlong2** — OpenStreetMap rendering
- **flutter_secure_storage** — encrypted key persistence
- **archive** — compression (declared but not yet actively used)

## Project Structure

```
lib/
  main.dart                         # Entry point, ProviderScope root
  app.dart                          # MaterialApp, bottom nav (Chat/Map/SOS)
  core/
    transport/                      # BLE hardware abstraction
      transport.dart                #   Abstract Transport interface
      transport_config.dart         #   Tunable constants (TTL, intervals, limits)
      ble_transport.dart            #   Concrete BLE implementation
    mesh/                           # Mesh network logic
      relay_controller.dart         #   Flood control / relay decisions
      topology_tracker.dart         #   Graph tracking, BFS routing
      deduplicator.dart             #   LRU + time-based packet dedup
      gossip_sync.dart              #   Anti-entropy gap-filling
    crypto/                         # Cryptography
      noise_protocol.dart           #   Noise XX handshake (full impl)
      noise_session.dart            #   Post-handshake encrypted session
      signatures.dart               #   Ed25519 packet signing
      keys.dart                     #   Key generation, storage, management
    identity/                       # Identity and groups
      peer_id.dart                  #   32-byte peer identity (SHA-256 of pubkey)
      identity_manager.dart         #   Local identity + peer trust
      group_cipher.dart             #   Group symmetric encryption (ChaCha20)
      group_manager.dart            #   Group lifecycle (create/join/leave)
    device/                         # Hardware abstractions
      device_services.dart          #   GpsService / PermissionService interfaces
    protocol/                       # Wire format
      message_types.dart            #   Enum of all packet types (0x01–0x0D)
      packet.dart                   #   FluxonPacket encode/decode
      binary_protocol.dart          #   Payload codecs (chat, location, emergency)
      padding.dart                  #   PKCS#7 padding
  shared/                           # Pure utilities
    hex_utils.dart                  #   Hex encode/decode
    logger.dart                     #   SecureLogger (no PII)
    compression.dart                #   zlib compress/decompress
    geo_math.dart                   #   Haversine distance
  features/                         # Feature modules (Clean Architecture slices)
    chat/
      chat_screen.dart              #   Chat UI
      chat_controller.dart          #   StateNotifier<ChatState>
      chat_providers.dart           #   Riverpod providers (incl. shared infra providers)
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
      data/
        emergency_repository.dart   #   Abstract interface
        mesh_emergency_repository.dart # Concrete mesh + 3x rebroadcast
    group/
      create_group_screen.dart      #   Group creation UI
      join_group_screen.dart        #   Group join UI
test/
  core/                             # Unit tests for mesh, crypto, protocol
  features/                         # Unit tests for controllers, repositories
  shared/                           # Unit tests for utilities
```

## Architecture Patterns

### Clean Architecture per Feature
Each feature follows: `Screen -> Controller (StateNotifier) -> Repository (abstract) -> MeshRepository (concrete)`. Controllers never import Transport, BinaryProtocol, or crypto directly.

### Dependency Inversion (DIP)
Every external dependency is behind an abstract interface:
- `Transport` (abstract) <- `BleTransport` (BLE)
- `ChatRepository` <- `MeshChatRepository`
- `LocationRepository` <- `MeshLocationRepository`
- `EmergencyRepository` <- `MeshEmergencyRepository`
- `GpsService` <- `GeolocatorGpsService`
- `PermissionService` <- `GeolocatorPermissionService`

### Riverpod DI
Infrastructure providers (`transportProvider`, `myPeerIdProvider`, `groupManagerProvider`) are defined in `chat_providers.dart` with `throw UnimplementedError()` — they **must** be overridden via `ProviderScope` overrides at the app root. Other feature providers reuse these.

### Dual Cryptography Layers
1. **Session layer**: Noise XX (X25519 + ChaCha20-Poly1305 + SHA256) per peer-pair
2. **Group layer**: Argon2id-derived symmetric key (ChaCha20-Poly1305) shared via passphrase
3. **Packet auth**: Ed25519 detached signatures on every packet

### Stream-Based Reactive Data Flow
`Transport` emits `Stream<FluxonPacket>` -> Repositories filter by MessageType -> Controllers subscribe and update StateNotifier state -> UI rebuilds via Riverpod.

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

**Important**: `sodium_libs` must be initialized before use (`SodiumInit.init()`). This is currently a TODO in `main.dart`.

## Key Constants (TransportConfig)

| Parameter | Default | Notes |
|---|---|---|
| Max TTL | 7 | Hop limit for flood routing |
| Max connections | 7 | BLE peer limit |
| Dedup cache | 1024 entries / 300s | Packet deduplication |
| Location broadcast | 10s | GPS share interval |
| Emergency rebroadcast | 3x / 500ms | SOS reliability |
| BLE scan interval | 2000ms | Discovery cadence |

## Known TODOs / Incomplete Wiring

- `main.dart`: `SodiumInit.init()`, `IdentityManager`, and `BleTransport` initialization are TODOs
- Screen widgets (chat, location, emergency) have local state — Riverpod controller wiring is scaffolded but not connected in `build()` methods
- Group screens return passphrases via `Navigator.pop()` but don't call `GroupManager` yet
- Group membership is in-memory only (no persistence across app restarts)
- Shared infra providers live in `chat_providers.dart` — ideally should be in a `core_providers.dart`
- Chat messages are **not** group-encrypted (location and emergency are)

## Conventions

- **Immutable state**: Controllers use `copyWith` pattern on state classes
- **SRP extraction**: Utility logic is extracted into dedicated classes (e.g., `GeoMath` from `LocationUpdate`, `GroupCipher` from `GroupManager`)
- **No PII logging**: `SecureLogger` is used throughout — never log keys, peer IDs, or locations
- **BLE service UUID**: `F1DF0001-1234-5678-9ABC-FLUXONLINK01`
- **Packet types**: Defined in `MessageType` enum (0x01–0x0D)
- **Tests**: Mirror the `lib/` structure under `test/`; use abstract interfaces for mocking
