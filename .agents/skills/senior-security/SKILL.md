---
name: senior-security
description: Flutter & BLE mesh security engineering skill for FluxonApp. Covers BLE transport security, Noise XX protocol auditing, libsodium crypto validation, secure storage, mobile platform hardening, and threat modeling for off-grid mesh networks. Use when reviewing crypto implementations, auditing BLE attack surface, hardening secure storage, or threat-modeling mesh network protocols.
---

# Senior Security - Flutter BLE Mesh

Security toolkit tailored for Flutter mobile apps with BLE mesh networking, libsodium cryptography, and off-grid communication protocols.

## Quick Start

### Main Capabilities

```bash
# Script 1: Threat Modeler — STRIDE analysis for BLE mesh topology
python scripts/threat_modeler.py lib/ --profile ble-mesh

# Script 2: Security Auditor — Static analysis of Dart crypto & storage patterns
python scripts/security_auditor.py lib/ --verbose

# Script 3: BLE Attack Surface Analyzer — BLE GATT/advertising exposure audit
python scripts/ble_attack_surface.py lib/ --scan-config
```

## Core Capabilities

### 1. Threat Modeler (BLE Mesh STRIDE)

Automated STRIDE threat modeling for BLE mesh network architectures.

**Features:**
- STRIDE analysis per mesh component (transport, relay, crypto, identity, protocol)
- BLE-specific threat enumeration (MITM, replay, relay attacks, MAC spoofing)
- Trust boundary mapping (phone ↔ BLE ↔ mesh ↔ peer)
- Data flow diagram generation for packet lifecycle

**Usage:**
```bash
python scripts/threat_modeler.py lib/ --profile ble-mesh --output threats.json
```

**Threat Categories Covered:**
| Category | BLE Mesh Examples |
|---|---|
| Spoofing | Fake peer ID, BLE MAC cloning, forged Noise handshake |
| Tampering | Packet modification in relay, TTL manipulation, payload injection |
| Repudiation | Unsigned packets, missing audit trail, deniable relay |
| Info Disclosure | BLE advertising leaks, unencrypted discovery, key material in logs |
| Denial of Service | Flood relay, dedup cache exhaustion, BLE connection saturation |
| Elevation | Group key theft, bypass group membership, relay privilege escalation |

### 2. Security Auditor (Dart Static Analysis)

Static analysis of Dart/Flutter code for security anti-patterns.

**Features:**
- Crypto misuse detection (hardcoded keys, weak RNG, nonce reuse patterns)
- Secure storage audit (flutter_secure_storage usage, key lifecycle)
- PII leak detection in logs (SecureLogger compliance)
- Permission over-request detection (Android/iOS manifests)
- Dependency vulnerability check (pub.dev advisories)

**Usage:**
```bash
python scripts/security_auditor.py lib/ --verbose
python scripts/security_auditor.py lib/ --check crypto     # Crypto-only scan
python scripts/security_auditor.py lib/ --check storage    # Storage-only scan
python scripts/security_auditor.py lib/ --check permissions # Permission audit
```

**Checks Performed:**
- `[CRIT]` Hardcoded cryptographic keys or secrets in source
- `[CRIT]` Use of `dart:math Random()` instead of `SecureRandom` for crypto
- `[CRIT]` Nonce/IV reuse in ChaCha20-Poly1305 or any AEAD
- `[HIGH]` PII (peer IDs, keys, locations) in print/log statements
- `[HIGH]` Unencrypted data written to SharedPreferences instead of SecureStorage
- `[HIGH]` Missing certificate pinning for network tile fetches
- `[MED]`  Overly broad Android/iOS permissions
- `[MED]`  Missing input validation on deserialized BLE packets
- `[LOW]`  Unused crypto imports, dead code in security-critical paths

### 3. BLE Attack Surface Analyzer

Audit of BLE GATT service exposure and advertising configuration.

**Features:**
- GATT characteristic permission audit (read/write/notify exposure)
- BLE advertising data leak analysis (what's broadcast in the clear)
- Connection parameter security (bonding, encryption requirements)
- Scan response data review
- Platform-specific BLE permission mapping

**Usage:**
```bash
python scripts/ble_attack_surface.py lib/ --scan-config
python scripts/ble_attack_surface.py lib/ --gatt-audit
```

## Reference Documentation

### Security Architecture Patterns

Comprehensive guide in `references/security_architecture_patterns.md`:

- Flutter secure storage patterns (key lifecycle, encrypted persistence)
- BLE transport security (GATT hardening, connection encryption)
- Mesh relay trust model (flood control, relay authorization)
- Defense-in-depth for off-grid apps (no server = no revocation authority)
- Platform hardening (Android manifest, iOS entitlements, root/jailbreak detection)

### BLE & Mobile Penetration Testing Guide

Workflow documentation in `references/penetration_testing_guide.md`:

- BLE sniffing and MITM setup (nRF Sniffer, BTLE tools)
- Noise XX handshake interception and replay testing
- Mesh packet injection and relay abuse
- Android app reverse engineering (APK analysis, Frida hooks)
- iOS runtime instrumentation for BLE and keychain
- Group key extraction from compromised device

### Cryptography Implementation

Technical reference in `references/cryptography_implementation.md`:

- Noise XX protocol correctness checklist (X25519, ChaChaPoly, SHA-256)
- Ed25519 signature verification flow
- Argon2id parameter tuning for mobile (memory, iterations, parallelism)
- Group cipher key derivation and rotation
- Nonce management strategies for ChaCha20-Poly1305
- libsodium (sodium_libs) Dart binding specifics and pitfalls

## Tech Stack Context

**Framework:** Flutter (Dart SDK ^3.10.8)
**BLE:** flutter_blue_plus (central), ble_peripheral (peripheral/advertising)
**Crypto:** sodium_libs (libsodium sumo — X25519, ChaCha20-Poly1305, Ed25519, Argon2id, BLAKE2b)
**State:** flutter_riverpod
**Storage:** flutter_secure_storage (encrypted key/group/profile persistence)
**Location:** geolocator + flutter_map (GPS + offline OSM tiles)
**Background:** flutter_foreground_task (Android foreground service for BLE relay)
**Permissions:** permission_handler

## Security-Critical Paths

These are the files/modules where security bugs have the highest impact:

| Priority | Module | Path | Risk |
|---|---|---|---|
| P0 | Noise XX Handshake | `lib/core/crypto/noise_protocol.dart` | Session key compromise |
| P0 | Noise Session | `lib/core/crypto/noise_session.dart` | Encryption bypass |
| P0 | Group Cipher | `lib/core/identity/group_cipher.dart` | Group message decryption |
| P0 | Key Management | `lib/core/crypto/keys.dart` | Identity theft |
| P0 | Packet Signing | `lib/core/crypto/signatures.dart` | Packet forgery |
| P1 | Packet Codec | `lib/core/protocol/packet.dart` | Malformed packet injection |
| P1 | Binary Protocol | `lib/core/protocol/binary_protocol.dart` | Payload parsing exploit |
| P1 | BLE Transport | `lib/core/transport/ble_transport.dart` | BLE-level attacks |
| P1 | Identity Manager | `lib/core/identity/identity_manager.dart` | Peer impersonation |
| P2 | Deduplicator | `lib/core/mesh/deduplicator.dart` | Cache poisoning / DoS |
| P2 | Relay Controller | `lib/core/mesh/relay_controller.dart` | Relay abuse |
| P2 | Secure Storage | `lib/core/identity/group_storage.dart` | Key extraction |
| P3 | Message Storage | `lib/core/services/message_storage_service.dart` | Plaintext message leak |

## Development Workflow

### 1. Pre-Implementation Threat Model

```bash
# Before adding new features, run threat model
python scripts/threat_modeler.py lib/ --profile ble-mesh

# Review generated STRIDE table for your feature area
```

### 2. Security Audit During Development

```bash
# Run full audit
python scripts/security_auditor.py lib/ --verbose

# Run crypto-specific checks after touching crypto/
python scripts/security_auditor.py lib/core/crypto/ --check crypto

# Run storage checks after touching identity/ or services/
python scripts/security_auditor.py lib/core/identity/ --check storage
```

### 3. BLE Surface Review

```bash
# After modifying BLE transport or advertising
python scripts/ble_attack_surface.py lib/core/transport/ --gatt-audit
```

### 4. Test Security Properties

```bash
# Run crypto and protocol tests
flutter test test/core/

# Run with coverage to verify security-critical paths are tested
flutter test --coverage
```

## Best Practices Summary

### Cryptography
- Never use `dart:math Random()` for anything security-related — always `SodiumSumo` RNG
- Generate fresh nonces for every ChaCha20-Poly1305 encryption (never reuse)
- Validate Ed25519 signatures before processing any received packet
- Use constant-time comparison for signature/MAC verification (libsodium provides this)
- Zeroize key material after use where possible

### BLE Security
- Minimize data in BLE advertising packets (no peer IDs, no group info)
- Validate all received BLE data lengths before parsing (buffer overflow prevention)
- Enforce max packet size limits at transport layer
- Rate-limit incoming BLE connections to prevent connection flooding
- Don't trust BLE MAC addresses for identity (they can be spoofed)

### Secure Storage
- All keys, group secrets, and identity material go through `flutter_secure_storage` only
- Never write crypto keys to SharedPreferences, files, or logs
- Use SecureLogger throughout — never log PeerId, keys, coordinates, or message content
- Clear sensitive data from memory when no longer needed

### Protocol Safety
- Always check TTL > 0 before relay (prevent infinite loops)
- Validate packet structure before crypto operations (parse then verify, not verify then parse)
- Reject packets with future timestamps beyond reasonable clock skew
- Enforce dedup cache limits to prevent memory exhaustion attacks

### Platform Hardening
- Request minimum required permissions (no `ACCESS_BACKGROUND_LOCATION` unless needed)
- Implement root/jailbreak detection for high-security deployments
- Use Android `NetworkSecurityConfig` to enforce HTTPS for tile fetching
- Enable iOS App Transport Security

## Common Commands

```bash
# Security analysis
python scripts/security_auditor.py lib/ --verbose
python scripts/threat_modeler.py lib/ --profile ble-mesh
python scripts/ble_attack_surface.py lib/ --scan-config

# Flutter testing
flutter test test/core/                         # All core (crypto, mesh, protocol)
flutter test test/core/noise_protocol_test.dart  # Noise XX tests
flutter test test/core/signatures_test.dart      # Ed25519 tests
flutter test test/core/group_cipher_test.dart    # Group encryption tests
flutter analyze                                  # Lint checks

# Dependency audit
flutter pub outdated                             # Check for updates
flutter pub deps                                 # Dependency tree
```

## Troubleshooting

### Common Security Issues

| Issue | Cause | Solution |
|---|---|---|
| Nonce reuse warning | Counter not incrementing | Use random nonce per encryption call |
| Signature verification fails | Wrong key or corrupted packet | Check Ed25519 key distribution in Noise messages 2 & 3 |
| SecureStorage empty on fresh install | Keys not generated | Verify `IdentityManager.initialize()` runs before key access |
| BLE packets accepted unsigned | Signature check skipped | Ensure `Signatures.verify()` called before `BinaryProtocol.decode()` |
| Group decryption fails | Wrong passphrase or key rotation | Verify Argon2id derivation params match across devices |

## Resources

- Pattern Reference: `references/security_architecture_patterns.md`
- Pentest Guide: `references/penetration_testing_guide.md`
- Crypto Guide: `references/cryptography_implementation.md`
- Tool Scripts: `scripts/` directory
