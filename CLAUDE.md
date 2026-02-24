# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Start

```bash
# Install dependencies
flutter pub get

# Run the app on a connected device or emulator
flutter run

# Run all tests (46 test files)
flutter test

# Run specific test directory
flutter test test/core/
flutter test test/features/

# Run a single test file
flutter test test/core/deduplicator_test.dart

# Analyze code for lint issues
flutter analyze

# Get test coverage (requires lcov)
flutter test --coverage
```

## What is FluxonApp?

FluxonApp is a Flutter mobile app for **off-grid, BLE mesh networking**. It enables phone-to-phone group chat, real-time location sharing, and emergency SOS alerts — all peer-to-peer without internet. Adapted from the Bitchat protocol with Fluxonlink-specific additions.

**Current status:** Phase 4 complete + performance/correctness hardening (v3.3). 50 test files, 627 tests passing. Zero compile errors.

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
- **audioplayers** — notification sound playback (two-tone chime on incoming messages)
- **archive** — compression (declared but not yet actively used)

## High-Level Architecture

```
UI Layer (Features)
  ├─ Chat (group messaging, display names)
  ├─ Location (GPS sharing, OpenStreetMap)
  ├─ Emergency (SOS alerts)
  ├─ Group (create/join group screens)
  ├─ Onboarding (first-run display name entry)
  └─ Device Terminal (debug serial console for Fluxon hardware)
        ↓
Controllers & Riverpod State Management
  ├─ StateNotifier-based controllers
  └─ Reactive providers for shared infrastructure
        ↓
Data Layer (Repositories)
  ├─ Abstract repository interfaces
  └─ Concrete mesh implementations
        ↓
Core Infrastructure
  ├─ Transport (BLE scanning/advertising, multi-hop relay via MeshService)
  ├─ Mesh Networking (relay, deduplication, topology tracking)
  ├─ Cryptography (Noise XX session layer, Ed25519 packet signing, ChaCha20-Poly1305 group encryption)
  ├─ Identity (peer ID derivation, group management, secure key storage)
  ├─ Protocol (binary packet encoding/decoding, message types)
  └─ Services (foreground service, notification sound, message persistence, receipt tracking)
```

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
      notification_sound.dart       #   Generates and plays notification chimes on incoming messages
      message_storage_service.dart  #   Persists chat messages per-group to local JSON files
      receipt_service.dart          #   Tracks message delivery status (double-tick indicators)
    protocol/                       # Wire format
      message_types.dart            #   Enum of all packet types (0x01–0x0E)
      packet.dart                   #   FluxonPacket encode/decode
      binary_protocol.dart          #   Payload codecs (chat with JSON senderName, location, emergency, discovery)
      padding.dart                  #   PKCS#7 padding
    providers/                      # Shared Riverpod providers
      group_providers.dart          #   groupManagerProvider + activeGroupProvider (reactive group state bridge)
      profile_providers.dart        #   userProfileManagerProvider + displayNameProvider
      transport_providers.dart      #   transportProvider, myPeerIdProvider, transportConfigProvider (canonical home)
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
      chat_providers.dart           #   Chat feature providers; re-exports transport providers from core/providers/
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
    device_terminal/               # Hardware debug console (NEW in Phase 4)
      device_terminal_screen.dart   #   Terminal UI (scan/connect, text/hex display)
      device_terminal_controller.dart # StateNotifier<DeviceTerminalState>, BLE lifecycle management
      device_terminal_providers.dart #   Riverpod providers for device terminal
      device_terminal_model.dart    #   TerminalMessage, ScannedDevice, enums (direction, display mode, connection status)
      data/
        device_terminal_repository.dart  #   Abstract interface
        ble_device_terminal_repository.dart # Direct BLE communication (bypasses mesh)
test/
  core/                             # 26 test files: mesh, crypto, protocol, transport, services
  features/                         # 11+ test files: controllers, repositories, screens, lifecycle
  shared/                           # Utility tests (geo_math)
  services/                         # Service tests
  widget_test.dart                  # Root widget smoke test
```

## Architecture Patterns

### Clean Architecture per Feature
Each feature follows: `Screen -> Controller (StateNotifier) -> Repository (abstract) -> MeshRepository (concrete)`. Controllers never import Transport, BinaryProtocol, or crypto directly.

### Dependency Inversion (DIP)
Every external dependency is behind an abstract interface:
- `Transport` (abstract) ← `BleTransport` (BLE) / `StubTransport` (tests & desktop)
- `Transport` (abstract) ← `MeshService` (wraps raw transport with multi-hop relay)
- `ChatRepository` ← `MeshChatRepository`
- `LocationRepository` ← `MeshLocationRepository`
- `EmergencyRepository` ← `MeshEmergencyRepository`
- `DeviceTerminalRepository` ← `BleDeviceTerminalRepository`
- `GpsService` ← `GeolocatorGpsService`
- `PermissionService` ← `GeolocatorPermissionService`

### Riverpod DI
Infrastructure providers (`transportProvider`, `myPeerIdProvider`, `transportConfigProvider`) are defined in `core/providers/transport_providers.dart`. `groupManagerProvider` lives in `core/providers/group_providers.dart`. All throw `UnimplementedError()` and **must** be overridden via `ProviderScope` at the app root (`main.dart`). `chat_providers.dart` re-exports the transport providers for backward compatibility.

Additional providers in Phase 4+:
- `activeGroupProvider` — `StateProvider<FluxonGroup?>` that bridges imperative `GroupManager` mutations with Riverpod's reactive system
- `userProfileManagerProvider` + `displayNameProvider` — reactive user display name state

### Dual Cryptography Layers
1. **Session layer**: Noise XX (X25519 + ChaCha20-Poly1305 + SHA256) per peer-pair
2. **Group layer**: Argon2id-derived symmetric key (ChaCha20-Poly1305) shared via passphrase
3. **Packet auth**: Ed25519 detached signatures on every packet (signing keys distributed via Noise handshake messages 2 & 3)

### Stream-Based Reactive Data Flow
`BleTransport` → `MeshService` (relay/dedup/topology filtering) → `Stream<FluxonPacket>` → Repositories filter by MessageType → Controllers subscribe and update StateNotifier state → UI rebuilds via Riverpod.

## Core Modules (Detailed)

### Transport (`lib/core/transport/`)
Abstract `Transport` interface implemented by:
- `BleTransport` — Central + peripheral BLE roles, handles scanning, advertising, GATT connections
- `StubTransport` — Test double with loopback, packet capture, and peer simulation (used on desktop/tests)

Key constants in `transport_config.dart`:
- Max TTL: 7 hops
- Fragment size: 469 bytes
- Dedup cache: 1000 entries / 300s TTL
- Location broadcast: 10s
- Emergency rebroadcast: 3x with 500ms spacing
- BLE scan interval: 2000ms
- Duty-cycle: 5s ON / 10s OFF when idle (>30s no activity)
- Max central links: 6 (iOS limit)

### Mesh Service (`lib/core/mesh/`)
Wraps raw transport with multi-hop relay orchestration:
- **MeshService** — Decides relay (flood control, TTL, topology), applies dedup, filters by topology
- **RelayController** — Implements relay decisions (flood vs unicast, TTL checks)
- **Deduplicator** — LRU + time-based dedup (key: source:timestamp:type)
- **TopologyTracker** — BFS routing graph, link-state propagation; route results cached for 5 s (keyed by source:target:maxHops), invalidated on any topology mutation
- **GossipSync** — Anti-entropy gap-filling for missed packets

### Cryptography (`lib/core/crypto/`)
- **SodiumInstance** — Global libsodium (Sumo) singleton, initialized once in `main.dart`
- **Noise XX** — Full X25519 + ChaCha20-Poly1305 + SHA256 handshake implementation
- **NoiseSessionManager** — Manages per-peer-pair Noise XX state machines
- **Ed25519 Signatures** — Packet authentication (detached signatures, keys distributed in Noise messages 2 & 3)
- **GroupCipher** — Group-level ChaCha20-Poly1305 encryption derived from Argon2id

### Protocol (`lib/core/protocol/`)
Binary packet format (big-endian):
```
[version:1][type:1][ttl:1][flags:1][timestamp:8][sourceId:32][destId:32][payloadLen:2][payload:N][signature:64]
```
- Header: 78 bytes, signature: 64 bytes
- Max TTL: 7, max payload: 512 bytes
- Broadcast: destId all zeros
- Packet ID (dedup key): sourceId:timestamp:type

Chat payload format:
- JSON with sender name: `{"n":"Alice","t":"Hello"}` (when senderName present)
- Plain UTF-8 fallback for legacy/empty names
- Detection via `{"n":` prefix

### Services (`lib/core/services/`)
- **ForegroundServiceManager** — Android background BLE relay (prevents process termination on background)
- **NotificationSoundService** — Generates 200ms two-tone chime (A5 → C6) in WAV, plays on non-local incoming chat messages
- **MessageStorageService** — Persists chat messages to per-group JSON files in app documents directory; writes are debounced (5 s) and batch-flushed (every 10 saves) to minimise I/O; `dispose()` cancels timer and flushes pending writes
- **ReceiptService** — Tracks and broadcasts message delivery status (double-tick indicators like WhatsApp); sends receipts as batched packets (up to 255 per packet) to reduce BLE traffic

## Startup Sequence (main.dart)

1. `FlutterForegroundTask.initCommunicationPort()` — Initialize foreground service port (web-guarded)
2. `WidgetsFlutterBinding.ensureInitialized()`
3. `ForegroundServiceManager.initialize()` — Configure Android foreground service
4. `await initSodium()` — Initialize global `SodiumSumo` instance
5. `Future.wait([IdentityManager.initialize(), GroupManager.initialize(), UserProfileManager.initialize()])` — Parallel init: generate/load Curve25519 keypair + restore groups + load display name (saves 300–500 ms cold start vs sequential)
8. Select transport: `BleTransport` (Android/iOS) or `StubTransport` (desktop/test)
9. Wrap with `MeshService` for multi-hop relay
10. `ProviderScope` overrides: `transportProvider`, `myPeerIdProvider`, `groupManagerProvider`, `userProfileManagerProvider`, `displayNameProvider`
11. Run app
12. After first frame: `_startBle(transport)` — Start BLE and foreground service asynchronously (avoids blocking permission dialogs)

## App Routing

- `FluxonApp` (`app.dart`) is a `ConsumerWidget` that watches `displayNameProvider`
- If display name is empty → renders `OnboardingScreen` (first-run name entry)
- Otherwise → renders `_HomeScreen` with bottom nav (Chat / Map / SOS / Device Terminal)
- Named routes: `/create-group`, `/join-group`

## Wire Protocol

Binary packet format with message types 0x01–0x0E:

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
| 0x09 | noiseEncrypted | Bitchat | Direct Noise-encrypted message (protocol only, no UI) |
| 0x0A | locationUpdate | Fluxonlink | GPS coordinate broadcast (group-encrypted) |
| 0x0B | groupJoin | Fluxonlink | Group join request |
| 0x0C | groupJoinResponse | Fluxonlink | Group join response |
| 0x0D | groupKeyRotation | Fluxonlink | Group key rotation |
| 0x0E | emergencyAlert | Fluxonlink | SOS broadcast (group-encrypted) |

## BLE Configuration

- **Service UUID**: `F1DF0001-1234-5678-9ABC-DEF012345678`
- **Characteristic UUID**: `F1DF0002-1234-5678-9ABC-DEF012345678`

## Platform Configuration

### Android (`AndroidManifest.xml`)
- Permissions: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (API 31+), `ACCESS_FINE_LOCATION` (BLE scan), `INTERNET` (OSM tiles), `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` (background relay)

### iOS (`Info.plist`)
- Background modes: `bluetooth-central`, `bluetooth-peripheral`, `location`
- Usage descriptions: NSBluetoothAlwaysUsageDescription, NSBluetoothPeripheralUsageDescription, NSLocationWhenInUseUsageDescription, NSLocationAlwaysAndWhenInUseUsageDescription

## Code Conventions

- **Immutable state**: Controllers use `copyWith` pattern on state classes
- **SRP extraction**: Utility logic in dedicated classes (e.g., `GeoMath` from `LocationUpdate`, `GroupCipher` from `GroupManager`)
- **No PII logging**: `SecureLogger` is used throughout — never log keys, peer IDs, or locations
- **Packet types**: Defined in `MessageType` enum (0x01–0x0E)
- **Tests**: Mirror the `lib/` structure under `test/`; use abstract interfaces for mocking
- **Platform-conditional transport**: `BleTransport` on mobile, `StubTransport` on desktop/test
- **Group-only UI**: Private chat protocol exists at repository level (`sendPrivateMessage`) but UI was removed in Phase 4
- **Reactive group state**: Create/Join/Leave group actions update both `GroupManager` (imperative) and `activeGroupProvider` (Riverpod reactive)
- **Display names**: Transmitted in JSON chat payload `{"n":"name","t":"text"}`, with plain UTF-8 fallback

## Testing

Run all tests:
```bash
flutter test
```

Run specific categories:
```bash
flutter test test/core/              # Transport, mesh, crypto, protocol
flutter test test/features/          # Controllers, repositories, screens
flutter test test/core/deduplicator_test.dart  # Single file
```

All 50 test files passing, 627 tests total. Tests use `mocktail` for mocking with abstract interface-based dependency injection.

## Phase Completion Status

| Phase | What | Status |
|---|---|---|
| Phase 1 | BLE chat between two phones | ✅ Complete |
| Phase 1.5 | Sodium API fixes, group infrastructure, main.dart overhaul | ✅ Complete |
| Phase 2 | Multi-hop mesh (MeshService, relay, topology) | ✅ Complete |
| Phase 3 | Noise XX encryption, signing key distribution, private chat protocol | ✅ Complete |
| Phase 4 | Background relay, duty-cycle BLE, offline maps, UI redesign, user names, onboarding, notification sound, message storage, receipt service, device terminal | ✅ Complete |

## Known TODOs / Future Work (Phase 5+)

- Multi-group support: Switch between groups or join multiple simultaneously
- Message delivery ACKs + read receipts: Protocol `MessageType.ack` exists but no send/receive logic
- Fragment reassembly: For payloads exceeding BLE MTU (if real devices negotiate MTU < 256)
- End-to-end field test: 3-device mesh, app backgrounded on middle device
- Performance profiling: Battery drain, memory footprint, relay latency under load

## Key Files to Read First

When onboarding, read these in order:
1. `lib/main.dart` — Startup and DI
2. `lib/core/transport/transport.dart` — Abstract interface
3. `lib/core/mesh/mesh_service.dart` — Relay orchestrator
4. `lib/core/protocol/packet.dart` — Packet encoding
5. `lib/features/chat/chat_screen.dart` — UI example
6. `lib/features/chat/chat_controller.dart` — Controller pattern
7. `test/core/deduplicator_test.dart` — Test example

## Troubleshooting

| Issue | Cause | Solution |
|---|---|---|
| Blank map in Location screen | Missing INTERNET permission or tile provider init | Check AndroidManifest.xml; provider has NetworkTileProvider fallback |
| BLE won't connect | Permission denied or Bluetooth off | Verify runtime permissions; user must enable Bluetooth |
| No incoming messages | Foreground service killed | Ensure foreground service starts after BLE, check Android settings |
| Tests fail on Windows | StubTransport platform logic | Run on Android/iOS or update platform guards |
| No notification sound | Audio permission or files in cache | Verify OS permissions; NotificationSoundService generates WAV on first use |
