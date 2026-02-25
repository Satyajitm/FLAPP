# 🗺️ FluxonApp — System Architecture Map

> **Purpose:** Exhaustive high-level inventory of every module in the codebase.  
> **Use this document to:** pick which vertical to deep-dive into next.  
> **Last updated:** 2026-02-25

---

## How to Use This Map

1. **Scan the Module Index** below to get a bird's-eye view of the entire system
2. **Check the Risk Heatmap** to prioritize which verticals need attention
3. **Pick a vertical** and run `/deep-dive` (see `.agent/workflows/deep-dive.md`)
4. After the deep-dive, **update the "Audit Status" column** in the Module Index

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              FluxonApp Architecture                             │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                         FEATURES (UI + Controllers)                     │    │
│  │  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌────────┐  │    │
│  │  │   Chat   │  │ Location │  │ Emergency │  │  Device  │  │ Group  │  │    │
│  │  │ Screen + │  │ Screen + │  │ Screen +  │  │ Terminal │  │ Create │  │    │
│  │  │Controller│  │Controller│  │Controller │  │ Screen + │  │ Join   │  │    │
│  │  │ +Repo    │  │ +Repo    │  │ +Repo     │  │Controller│  │ Share  │  │    │
│  │  └────┬─────┘  └────┬─────┘  └────┬──────┘  └────┬─────┘  └───┬────┘  │    │
│  └───────┼──────────────┼──────────────┼──────────────┼────────────┼───────┘    │
│          │              │              │              │            │             │
│  ┌───────▼──────────────▼──────────────▼──────────────▼────────────▼───────┐    │
│  │                         PROVIDERS (Riverpod DI)                         │    │
│  │  transportProvider │ groupManagerProvider │ myPeerIdProvider │ etc.     │    │
│  └───────┬─────────────────────────────┬──────────────────────────────────┘    │
│          │                             │                                        │
│  ┌───────▼─────────────────────────────▼──────────────────────────────────┐    │
│  │                         CORE SERVICES                                   │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐  ┌──────────┐  │    │
│  │  │ MeshService   │  │MessageStorage│  │ForegroundSvc   │  │ Receipt  │  │    │
│  │  │ (relay,gossip │  │ (at-rest     │  │ (Android       │  │ Service  │  │    │
│  │  │  topology)    │  │  encryption) │  │  lifecycle)    │  │          │  │    │
│  │  └──────┬────────┘  └──────────────┘  └────────────────┘  └──────────┘  │    │
│  └─────────┼──────────────────────────────────────────────────────────────┘    │
│            │                                                                    │
│  ┌─────────▼──────────────────────────────────────────────────────────────┐    │
│  │                         TRANSPORT LAYER                                 │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐                │    │
│  │  │ BleTransport  │  │StubTransport │  │ TransportConfig│                │    │
│  │  │ (BLE dual-    │  │ (desktop/web │  │ (tuning knobs) │                │    │
│  │  │  role GATT)   │  │  fallback)   │  │                │                │    │
│  │  └──────┬────────┘  └──────────────┘  └────────────────┘                │    │
│  └─────────┼──────────────────────────────────────────────────────────────┘    │
│            │                                                                    │
│  ┌─────────▼──────────────────────────────────────────────────────────────┐    │
│  │                         PROTOCOL LAYER                                  │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  ┌────────────────┐  │    │
│  │  │BinaryProtocol │  │ FluxonPacket │  │  Padding │  │  MessageTypes  │  │    │
│  │  │ (encode/      │  │ (wire        │  │ (PKCS#7) │  │  (enum)        │  │    │
│  │  │  decode)      │  │  format)     │  │          │  │                │  │    │
│  │  └──────────────┘  └──────────────┘  └──────────┘  └────────────────┘  │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐    │
│  │                         CRYPTO LAYER                                    │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐   │    │
│  │  │NoiseProtocol  │  │ NoiseSession │  │NoiseSessionMgr│ │Signatures│   │    │
│  │  │ (XX handshake │  │ (transport   │  │ (per-peer     │  │(Ed25519) │   │    │
│  │  │  state machine│  │  encrypt)    │  │  lifecycle)   │  │          │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘   │    │
│  │  ┌──────────────┐  ┌──────────────┐                                    │    │
│  │  │ Keys          │  │SodiumInstance│                                    │    │
│  │  │ (generation,  │  │ (global init)│                                    │    │
│  │  │  storage)     │  │              │                                    │    │
│  │  └──────────────┘  └──────────────┘                                    │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐    │
│  │                         IDENTITY LAYER                                  │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐   │    │
│  │  │IdentityMgr    │  │ GroupManager │  │ GroupCipher   │  │GroupStore│   │    │
│  │  │ (keys, trust, │  │ (create/join │  │ (Argon2id +   │  │(secure   │   │    │
│  │  │  TOFU)        │  │  leave)      │  │  AEAD)        │  │ storage) │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘   │    │
│  │  ┌──────────────┐  ┌──────────────┐                                    │    │
│  │  │ PeerId        │  │UserProfileMgr│                                    │    │
│  │  │ (32-byte hash)│  │ (display name│                                    │    │
│  │  └──────────────┘  └──────────────┘                                    │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐    │
│  │                         SHARED UTILITIES                                │    │
│  │  hex_utils.dart │ logger.dart │ compression.dart │ geo_math.dart       │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐    │
│  │                         APP SHELL                                       │    │
│  │  main.dart (bootstrap + DI) │ app.dart (MaterialApp + navigation)      │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Module Index

Each module is a self-contained vertical that can be independently audited.

### LAYER 1: Core Infrastructure

| # | Module | Path | Files | Size | Depends On | Risk | Audit Status |
|---|--------|------|-------|------|------------|------|-------------|
| **V1** | **Cryptography** | `lib/core/crypto/` | `noise_protocol.dart` (20KB), `noise_session_manager.dart` (13KB), `keys.dart` (10KB), `signatures.dart` (3KB), `noise_session.dart` (2KB), `sodium_instance.dart` (1KB) | ~50KB | sodium_libs, flutter_secure_storage | 🔴 Critical | ✅ Audited v2 — [CRYPTO_SECURITY_AUDIT_v2.md](CRYPTO_SECURITY_AUDIT_v2.md) |
| **V2** | **Identity & Groups** | `lib/core/identity/` | `group_cipher.dart` (9KB), `group_manager.dart` (7KB), `identity_manager.dart` (5KB), `group_storage.dart` (4KB), `peer_id.dart` (2KB), `user_profile_manager.dart` (1KB) | ~28KB | V1 (crypto), flutter_secure_storage | 🟠 High | ✅ Audited — [DEEP_DIVE_V2_IDENTITY.md](DEEP_DIVE_V2_IDENTITY.md) |
| **V3** | **Transport (BLE)** | `lib/core/transport/` | `ble_transport.dart` (36KB), `stub_transport.dart` (2KB), `transport.dart` (2KB), `transport_config.dart` (2KB) | ~42KB | V1 (crypto), V6 (protocol), flutter_blue_plus, ble_peripheral | 🔴 Critical | ✅ Audited — [BLE_SECURITY_AUDIT.md](BLE_SECURITY_AUDIT.md) |
| **V4** | **Mesh Networking** | `lib/core/mesh/` | `mesh_service.dart` (13KB), `topology_tracker.dart` (7KB), `gossip_sync.dart` (5KB), `deduplicator.dart` (3KB), `relay_controller.dart` (3KB) | ~31KB | V3 (transport), V6 (protocol), V1 (crypto) | 🟠 High | ✅ Audited — [DEEP_DIVE_V4_MESH.md](DEEP_DIVE_V4_MESH.md) |
| **V5** | **Services** | `lib/core/services/` | `message_storage_service.dart` (11KB), `receipt_service.dart` (6KB), `foreground_service_manager.dart` (3KB), `notification_sound.dart` (3KB) | ~23KB | V1 (crypto), path_provider, flutter_secure_storage | 🟡 Medium | ⚠️ MessageStorage covered by crypto audit |
| **V6** | **Protocol** | `lib/core/protocol/` | `binary_protocol.dart` (12KB), `packet.dart` (6KB), `padding.dart` (1KB), `message_types.dart` (1KB) | ~20KB | (none — leaf module) | 🟡 Medium | ✅ Audited — [DEEP_DIVE_V6_PROTOCOL.md](DEEP_DIVE_V6_PROTOCOL.md) |
| **V7** | **Providers (DI)** | `lib/core/providers/` | `transport_providers.dart` (1KB), `group_providers.dart` (1KB), `profile_providers.dart` (1KB) | ~3KB | flutter_riverpod | 🟢 Low | ❌ Not audited |
| **V8** | **Device** | `lib/core/device/` | `device_services.dart` (2KB) | ~2KB | device_info_plus, platform | 🟢 Low | ❌ Not audited |

### LAYER 2: Features (UI + Business Logic)

| # | Module | Path | Files | Size | Depends On | Risk | Audit Status |
|---|--------|------|-------|------|------------|------|-------------|
| **V9** | **Chat Feature** | `lib/features/chat/` | `chat_screen.dart` (23KB), `chat_controller.dart` (7KB), `chat_providers.dart` (3KB), `message_model.dart` (3KB), `data/chat_repository.dart` (2KB), `data/mesh_chat_repository.dart` (6KB) | ~44KB | V4 (mesh), V2 (groups), V5 (storage) | 🟡 Medium | ❌ Not security-audited |
| **V10** | **Location Feature** | `lib/features/location/` | `location_screen.dart` (5KB), `location_controller.dart` (4KB), `location_providers.dart` (2KB), `location_model.dart` (1KB), `data/location_repository.dart` (1KB), `data/mesh_location_repository.dart` (5KB) | ~18KB | V4 (mesh), V2 (groups) | 🟡 Medium | ❌ Not security-audited |
| **V11** | **Emergency Feature** | `lib/features/emergency/` | `emergency_screen.dart` (6KB), `emergency_controller.dart` (6KB), `emergency_providers.dart` (1KB), `data/emergency_repository.dart` (1KB), `data/mesh_emergency_repository.dart` (4KB) | ~18KB | V4 (mesh), V2 (groups) | 🟠 High | ✅ Audited — [DEEP_DIVE_V11_EMERGENCY.md](DEEP_DIVE_V11_EMERGENCY.md) |
| **V12** | **Device Terminal** | `lib/features/device_terminal/` | `device_terminal_screen.dart` (21KB), `device_terminal_controller.dart` (6KB), `device_terminal_providers.dart` (1KB), `device_terminal_model.dart` (2KB), `data/device_terminal_repository.dart` (1KB), `data/ble_device_terminal_repository.dart` (6KB) | ~37KB | V3 (transport) | 🟡 Medium | ❌ Not security-audited |
| **V13** | **Group Management (UI)** | `lib/features/group/` | `create_group_screen.dart` (6KB), `join_group_screen.dart` (10KB), `share_group_screen.dart` (7KB) | ~23KB | V2 (identity/groups) | 🟡 Medium | ❌ Not security-audited |
| **V14** | **Onboarding** | `lib/features/onboarding/` | `onboarding_screen.dart` (5KB) | ~5KB | V7 (providers) | 🟢 Low | ❌ Not audited |

### LAYER 3: App Shell & Shared

| # | Module | Path | Files | Size | Depends On | Risk | Audit Status |
|---|--------|------|-------|------|------------|------|-------------|
| **V15** | **App Bootstrap** | `lib/` | `main.dart` (4KB), `app.dart` (5KB) | ~9KB | All modules | 🟡 Medium | ❌ Not audited |
| **V16** | **Shared Utilities** | `lib/shared/` | `hex_utils.dart` (2KB), `logger.dart` (1KB), `compression.dart` (1KB), `geo_math.dart` (1KB) | ~5KB | (none — leaf module) | 🟡 Medium | ⚠️ `hex_utils` covered by crypto audit |

---

## Risk Heatmap

Priority order for security deep-dives, considering: data sensitivity, attack surface, existing coverage, and blast radius.

```
RISK vs AUDIT COVERAGE

              Unaudited ◄───────────────────────────► Fully Audited
                  │                                        │
    Critical ─────┤  V11 Emergency ⚠️                      │  V1 Crypto ✅
                  │  V6 Protocol ⚠️                        │  V3 BLE ✅
                  │                                        │
    High ─────────┤  V4 Mesh ⚠️                            │
                  │  V2 Identity ⚠️                        │
                  │                                        │
    Medium ───────┤  V9 Chat                               │
                  │  V12 DeviceTerminal                    │  V5 Services (partial)
                  │  V10 Location                          │  V16 Shared (partial)
                  │  V13 Group UI                          │
                  │  V15 App Bootstrap                     │
                  │                                        │
    Low ──────────┤  V14 Onboarding                        │
                  │  V7 Providers                          │
                  │  V8 Device                             │
                  │                                        │
```

### Recommended Deep-Dive Order

| Priority | Vertical | Why |
|----------|----------|-----|
| **P0** | **V11 — Emergency Feature** | Safety-critical; unaudited; sends alerts via mesh. A bug here could suppress or forge SOS alerts. |
| **P1** | **V6 — Protocol Layer** | Lowest-level parser; every byte from BLE flows through `BinaryProtocol.decode()`. Parser bugs = RCE surface. Never independently audited. |
| **P2** | **V4 — Mesh Networking** | Relay, gossip, topology. Controls who sees what. Partially covered but deserves dedicated pass for relay injection, topology poisoning, gossip amplification. |
| **P3** | **V2 — Identity & Groups** | Trust model, group lifecycle. Partially covered by crypto audit but group passphrase handling, join flow, and storage deserve own pass. |
| **P4** | **V9 — Chat Feature** | 44KB of UI + business logic. Largest feature. Message injection, XSS-in-WebView (if any), input validation. |
| **P5** | **V12 — Device Terminal** | 37KB. Sends raw BLE commands. If the terminal has any command injection surface, it's exploitable. |
| **P6** | **V10 — Location Feature** | GPS data handling, privacy implications. |
| **P7** | **V13 — Group UI** | Passphrase input handling, share code generation. |
| **P8** | **V15 — App Bootstrap** | Init order, error handling, permission model. |
| **P9** | **V5 — Services** | Receipt service, foreground service, notification. |
| **P10** | **V16 — Shared** | Small surface area but cryptographically important (hex_utils already audited). |

---

## Dependency Graph

Shows which modules depend on which, and the trust boundaries between them.

```
V14 Onboarding ──▶ V7 Providers ──▶ V15 App Bootstrap
                                          │
                    ┌─────────────────────┤
                    ▼                     ▼
              V13 Group UI          V9 Chat Feature ──────────▶ V5 Services
                    │                  │      │                     │
                    ▼                  ▼      ▼                     ▼
              V2 Identity        V4 Mesh    V10 Location        V1 Crypto
                    │              │   │        │
                    │              │   ▼        │
                    │              │ V11 Emergency
                    │              │
                    ▼              ▼
              V1 Crypto      V3 Transport (BLE)
                    │              │
                    ▼              ▼
              V16 Shared     V6 Protocol
                              │
                              ▼
                         V16 Shared
```

### Trust Boundaries

```
┌──────────────────────────────────────────────────────────┐
│  TRUSTED ZONE (local device)                             │
│                                                          │
│  V7, V8, V14, V15 — App shell, providers, device info   │
│  V5 — Services (local storage, notifications)            │
│                                                          │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  VALIDATION BOUNDARY                                     │
│                                                          │
│  V2 — Identity (manages keys, trust decisions)           │
│  V1 — Crypto (authenticates, encrypts)                   │
│  V6 — Protocol (parses untrusted wire bytes)             │
│                                                          │
│  ═══════════════════════════════════════════════════════  │
│  UNTRUSTED ZONE (remote peers via BLE)                   │
│                                                          │
│  V3 — Transport (BLE radio — any device in range)        │
│  V4 — Mesh (relayed packets from peers-of-peers)         │
│  V9, V10, V11 — Features (process data from mesh)        │
│  V12 — Device Terminal (raw BLE device communication)    │
└──────────────────────────────────────────────────────────┘
```

---

## Test Coverage Map

| # | Module | Test Files | Test LOC | Notes |
|---|--------|-----------|----------|-------|
| V1 | Crypto | `keys_test`, `noise_session_test`, `noise_session_manager_test`, `identity_signing_lifecycle_test`, `mesh_service_signing_test` | ~50K chars | Crypto tests need native sodium — most run as integration tests |
| V2 | Identity | `group_cipher_test`, `group_manager_test`, `group_storage_test`, `identity_manager_test`, `peer_id_test`, `user_profile_manager_test` | ~42K chars | Good coverage |
| V3 | Transport | `ble_transport_logic_test`, `stub_transport_test`, `duty_cycle_test`, `security_hardening_test` | ~53K chars | Comprehensive |
| V4 | Mesh | `mesh_service_test`, `mesh_relay_integration_test`, `gossip_sync_test`, `topology_test`, `relay_controller_test`, `deduplicator_test` | ~69K chars | Strong |
| V5 | Services | `foreground_service_manager_test`, `services/` | ~4K chars | **Weak — receipt_service, notification_sound untested** |
| V6 | Protocol | `binary_protocol_discovery_test`, `packet_test`, `packet_immutability_test`, `padding_test`, `protocol/` | ~19K chars | Moderate |
| V7 | Providers | (none) | 0 | ❌ No tests |
| V8 | Device | `device_services_test` | ~2K chars | Minimal |
| V9 | Chat | `chat_controller_test`, `chat_screen_test`, `chat_integration_test`, `chat_repository_test`, `message_model_test` | ~70K chars | Strong |
| V10 | Location | `location_controller_test`, `location_screen_test`, `location_test`, `mesh_location_repository_test` | ~26K chars | Moderate |
| V11 | Emergency | `emergency_controller_test`, `emergency_screen_test`, `emergency_repository_test` | ~31K chars | Moderate |
| V12 | Device Terminal | `device_terminal_controller_test`, `device_terminal_model_test` | ~10K chars | Weak — no screen test |
| V13 | Group UI | `group_screens_test`, `share_group_screen_test` | ~31K chars | Good |
| V14 | Onboarding | `onboarding_screen_test` | ~6K chars | Adequate |
| V15 | App Shell | `widget_test`, `app_lifecycle_test` | ~8K chars | Minimal |

---

## Existing Audit Reports

| Report | Created | Scope | Verticals Covered |
|--------|---------|-------|-------------------|
| `SECURITY_AUDIT_REPORT.md` | 2026-02-24 | Full repo | V1-V16 (broad) |
| `BLE_SECURITY_AUDIT.md` | 2026-02-24 | BLE transport | V3, partial V4 |
| `CRYPTO_SECURITY_AUDIT.md` | 2026-02-25 | Crypto layer | V1, partial V2 |
| `CRYPTO_SECURITY_AUDIT_v2.md` | 2026-02-25 | Crypto layer v2 | V1, partial V2, V3 integration |
| `FLUTTER_TESTING_AUDIT.md` | 2026-02-24 | Testing gaps | V1-V16 (testing) |
| `DEEP_DIVE_V2_IDENTITY.md` | 2026-02-25 | Identity & Groups deep-dive | V2 (full), partial V13 (Group UI) |
| `DEEP_DIVE_V4_MESH.md` | 2026-02-25 | Mesh Networking deep-dive | V4 (full) |
| `DEEP_DIVE_V6_PROTOCOL.md` | 2026-02-25 | Protocol Layer deep-dive | V6 (full) |
| `DEEP_DIVE_V11_EMERGENCY.md` | 2026-02-25 | Emergency Feature deep-dive | V11 (full) |
| `CODE_OPTIMIZATION_REPORT.md` | 2026-02-24 | Performance | V1-V16 (perf) |
| `FRONTEND_BUG_ANALYSIS.md` | ???? | UI bugs | V9-V14 |

---

## Quick Reference: File → Vertical Mapping

Use this to quickly identify which vertical a file belongs to.

```
lib/
├── main.dart                           → V15 App Bootstrap
├── app.dart                            → V15 App Bootstrap
├── core/
│   ├── crypto/
│   │   ├── keys.dart                   → V1 Cryptography
│   │   ├── noise_protocol.dart         → V1 Cryptography
│   │   ├── noise_session.dart          → V1 Cryptography
│   │   ├── noise_session_manager.dart  → V1 Cryptography
│   │   ├── signatures.dart             → V1 Cryptography
│   │   └── sodium_instance.dart        → V1 Cryptography
│   ├── identity/
│   │   ├── identity_manager.dart       → V2 Identity & Groups
│   │   ├── group_manager.dart          → V2 Identity & Groups
│   │   ├── group_cipher.dart           → V2 Identity & Groups
│   │   ├── group_storage.dart          → V2 Identity & Groups
│   │   ├── peer_id.dart                → V2 Identity & Groups
│   │   └── user_profile_manager.dart   → V2 Identity & Groups
│   ├── transport/
│   │   ├── ble_transport.dart          → V3 Transport (BLE)
│   │   ├── stub_transport.dart         → V3 Transport (BLE)
│   │   ├── transport.dart              → V3 Transport (BLE)
│   │   └── transport_config.dart       → V3 Transport (BLE)
│   ├── mesh/
│   │   ├── mesh_service.dart           → V4 Mesh Networking
│   │   ├── topology_tracker.dart       → V4 Mesh Networking
│   │   ├── gossip_sync.dart            → V4 Mesh Networking
│   │   ├── deduplicator.dart           → V4 Mesh Networking
│   │   └── relay_controller.dart       → V4 Mesh Networking
│   ├── services/
│   │   ├── message_storage_service.dart → V5 Services
│   │   ├── receipt_service.dart         → V5 Services
│   │   ├── foreground_service_manager.dart → V5 Services
│   │   └── notification_sound.dart      → V5 Services
│   ├── protocol/
│   │   ├── binary_protocol.dart        → V6 Protocol
│   │   ├── packet.dart                 → V6 Protocol
│   │   ├── padding.dart                → V6 Protocol
│   │   └── message_types.dart          → V6 Protocol
│   ├── providers/
│   │   ├── transport_providers.dart    → V7 Providers
│   │   ├── group_providers.dart        → V7 Providers
│   │   └── profile_providers.dart      → V7 Providers
│   └── device/
│       └── device_services.dart        → V8 Device
├── features/
│   ├── chat/                           → V9 Chat Feature
│   ├── location/                       → V10 Location Feature
│   ├── emergency/                      → V11 Emergency Feature
│   ├── device_terminal/                → V12 Device Terminal
│   ├── group/                          → V13 Group Management UI
│   └── onboarding/                     → V14 Onboarding
└── shared/
    ├── hex_utils.dart                  → V16 Shared Utilities
    ├── logger.dart                     → V16 Shared Utilities
    ├── compression.dart                → V16 Shared Utilities
    └── geo_math.dart                   → V16 Shared Utilities
```
