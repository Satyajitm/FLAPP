# Penetration Testing Guide — Flutter BLE Mesh App

## Overview

Penetration testing guide for FluxonApp, a Flutter BLE mesh networking app. Covers BLE-layer attacks, mesh protocol abuse, crypto implementation testing, mobile app reverse engineering, and physical device attacks. All testing assumes authorized security assessment of your own application.

## Testing Environment Setup

### Required Tools

| Tool | Purpose | Platform |
|---|---|---|
| nRF Connect | BLE scanning, GATT exploration, characteristic read/write | Android/iOS |
| Wireshark + nRF Sniffer | BLE packet capture at link layer | Desktop + nRF52840 dongle |
| Frida | Runtime instrumentation, hook Dart/native functions | Desktop → Android/iOS |
| objection | Frida-based mobile app exploration | Desktop |
| jadx / apktool | Android APK decompilation and analysis | Desktop |
| Hopper / Ghidra | Native binary analysis (libsodium, Flutter engine) | Desktop |
| adb | Android Debug Bridge for app data extraction | Desktop |
| idevice* tools | iOS device interaction (libimobiledevice) | Desktop (macOS/Linux) |
| Flutter DevTools | Dart VM inspection, widget tree, network | Desktop |

### Test Device Setup

```bash
# Android — enable USB debugging, install test APK
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# Verify BLE permissions granted
adb shell dumpsys package com.fluxonlink.app | grep -i permission

# Check app storage location
adb shell run-as com.fluxonlink.app ls /data/data/com.fluxonlink.app/
```

## Phase 1: Reconnaissance

### 1.1 BLE Service Discovery

Using nRF Connect or programmatic scanning, enumerate what FluxonApp exposes:

**What to look for:**
- Service UUID: `F1DF0001-1234-5678-9ABC-DEF012345678`
- Characteristic UUID: `F1DF0002-1234-5678-9ABC-DEF012345678`
- Characteristic permissions (read, write, notify, indicate)
- Advertising data content (device name, manufacturer data, service data)

**Questions to answer:**
- Is the device name included in advertising? (identity leak)
- Is any application data in manufacturer-specific data fields?
- Are characteristics readable without authentication?
- Can you write arbitrary data to the characteristic?

### 1.2 Advertising Data Analysis

```bash
# Using hcitool (Linux) to capture advertising
sudo hcitool lescan --duplicates

# Using btlejuice for BLE MITM (if applicable)
# Note: FluxonApp uses application-layer crypto, so BLE-level MITM
# reveals encrypted packets only
```

**Check:**
- Does advertising leak peer ID, group membership, or display name?
- How often does the device advertise? (trackability)
- Does the BLE MAC address rotate? (iOS does this by default, Android may not)

### 1.3 APK/IPA Static Analysis

```bash
# Decompile Android APK
jadx build/app/outputs/flutter-apk/app-release.apk -d jadx_output/

# Look for hardcoded secrets
grep -r "secret\|key\|password\|token" jadx_output/

# Check for debug flags left on
grep -r "kDebugMode\|debugPrint\|assert" jadx_output/

# Extract Flutter assets
unzip app-release.apk -d apk_contents/
ls apk_contents/assets/flutter_assets/
```

**What to look for in static analysis:**
- Hardcoded UUIDs, keys, or credentials
- Debug logging left enabled in release builds
- Obfuscation level (Flutter compiles to native, but Dart strings may be visible)
- Native library versions (libsodium, Flutter engine)

## Phase 2: BLE Transport Attacks

### 2.1 Packet Injection

**Goal:** Send crafted packets to the GATT characteristic and observe behavior.

```
Test cases:
1. Empty payload (0 bytes) — should be rejected, not crash
2. Undersized header (< 78 bytes) — should be rejected
3. Oversized packet (> max packet size) — should be rejected
4. Valid header + garbage payload — should fail signature check
5. Valid header + valid signature + wrong group key — should fail decryption
6. Replay: capture and resend a valid packet — should be deduped
```

**Using nRF Connect:**
1. Connect to FluxonApp device
2. Navigate to service `F1DF0001-...`
3. Write hex data to characteristic `F1DF0002-...`
4. Monitor app behavior (crash? hang? error log?)

### 2.2 Connection Flooding

**Goal:** Exhaust the device's BLE connection slots.

```
1. Connect 6+ devices simultaneously (iOS limit is 6 central links)
2. Hold connections open without sending data
3. Observe: does the app degrade gracefully or crash?
4. Does it disconnect stale connections?
5. Can new legitimate connections still be established?
```

**Expected behavior:** App should enforce `TransportConfig.maxCentralLinks` and reject/close excess connections.

### 2.3 BLE MITM (Link Layer)

**Note:** FluxonApp uses application-layer encryption (Noise XX + group cipher), so BLE-level MITM reveals only ciphertext. However, test whether:

- Noise XX handshake can be intercepted and replayed
- Handshake messages are order-dependent (state machine correctness)
- Downgrade attack: can you force communication without Noise session?

## Phase 3: Mesh Protocol Attacks

### 3.1 Replay Attack

**Goal:** Capture a valid signed packet and replay it.

```
1. Capture a valid packet (via BLE sniffing or StubTransport)
2. Re-inject the exact same bytes
3. Expected: Deduplicator rejects it (key: sourceId:timestamp:type)
4. Wait for dedup cache TTL (300s) and replay — does it succeed?
```

**Dedup bypass vectors:**
- Modify timestamp slightly — signature should fail
- Modify source ID — signature should fail
- Wait for cache expiry — packet is stale but may be accepted (check timestamp validation)

### 3.2 TTL Manipulation

**Goal:** Craft packets with manipulated TTL values.

```
1. TTL = 0: should not be relayed (but should be processed locally?)
2. TTL = 255: will it relay excessively? (max should be 7)
3. TTL = -1 (underflow): how does unsigned byte handle this?
```

**Expected:** `RelayController` enforces `TTL <= TransportConfig.maxTtl` (7).

### 3.3 Flood Attack

**Goal:** Send many unique packets rapidly to overwhelm relay and dedup.

```
1. Generate thousands of unique packets (different timestamps)
2. Inject via BLE connection
3. Monitor: memory usage, CPU, battery drain
4. Does dedup cache (1000 entries) handle eviction correctly?
5. Does relay rate-limiting kick in?
```

### 3.4 Topology Poisoning

**Goal:** Send fake topology announcements to corrupt the mesh routing graph.

```
1. Craft topologyAnnounce (0x03) packets with fake link-state data
2. Inject into the mesh
3. Does TopologyTracker validate the source?
4. Can you create routing loops?
5. Can you partition the mesh by advertising false links?
```

**Expected:** Topology announcements should be signed and verified.

## Phase 4: Cryptography Testing

### 4.1 Noise XX Handshake Verification

**Test checklist:**
- [ ] Ephemeral keys are unique per handshake (never reused)
- [ ] Out-of-order handshake messages are rejected
- [ ] Incomplete handshakes time out and are cleaned up
- [ ] Session keys differ between sessions (even same peer pair)
- [ ] Static key transmitted encrypted (not visible in msg1)
- [ ] Handshake aborted if peer static key is unknown/untrusted

### 4.2 Nonce Reuse Detection

**Goal:** Verify that ChaCha20-Poly1305 nonces are never reused with the same key.

```
1. Capture multiple encrypted packets from same sender
2. Extract nonces from each
3. Verify all nonces are unique
4. Test: send same plaintext twice — ciphertext should differ
```

**Why it matters:** Nonce reuse with ChaCha20-Poly1305 allows plaintext recovery via XOR of ciphertexts.

### 4.3 Ed25519 Signature Bypass

**Goal:** Test if unsigned or mis-signed packets are processed.

```
1. Send packet with zeroed signature — should be rejected
2. Send packet with signature from different key — should be rejected
3. Send packet with valid signature but modified payload — should be rejected
4. Send packet with no signature field (truncated) — should be rejected at parsing
```

### 4.4 Group Key Brute Force Assessment

**Goal:** Estimate feasibility of brute-forcing the group passphrase.

```
Argon2id parameters:
- opsLimit: Moderate (3 iterations)
- memLimit: Moderate (256 MB)

At these settings, each passphrase attempt takes ~1-3 seconds on mobile.
On GPU: Argon2id is memory-hard, so GPU advantage is limited.

Risk assessment:
- 4-char passphrase: trivially brute-forceable
- 8-char random: ~years at moderate settings
- Dictionary word: vulnerable to dictionary attack
```

**Recommendation:** Enforce minimum passphrase length and complexity in UI.

## Phase 5: Mobile App Security

### 5.1 Data-at-Rest Extraction

```bash
# Android: extract app data (requires root or debug build)
adb shell run-as com.fluxonlink.app tar czf /sdcard/fluxon_data.tar.gz .
adb pull /sdcard/fluxon_data.tar.gz

# Examine what's stored
tar xzf fluxon_data.tar.gz
find . -name "*.json" -exec cat {} \;  # message storage
find . -name "*.xml" -exec cat {} \;   # shared preferences
```

**What to look for:**
- Chat messages in plaintext JSON files (known — `MessageStorageService`)
- Keys in shared preferences instead of secure storage
- Group passphrases or derived keys anywhere outside keychain
- Location history persisted to disk

### 5.2 Runtime Instrumentation (Frida)

```javascript
// Hook Dart functions via Frida (requires knowledge of Dart internals)
// Example: hook GroupCipher.decrypt to log plaintext
Java.perform(function() {
  // Flutter uses native compilation, so hooking requires
  // finding function addresses in libapp.so

  // More practical: hook libsodium native calls
  var sodium_open = Module.findExportByName("libsodium.so",
    "crypto_aead_chacha20poly1305_ietf_open");

  if (sodium_open) {
    Interceptor.attach(sodium_open, {
      onEnter: function(args) {
        console.log("[*] ChaCha20 decrypt called");
        console.log("    ciphertext len: " + args[1].toInt32());
      },
      onLeave: function(retval) {
        console.log("    result: " + retval.toInt32());
        // 0 = success, -1 = auth failure
      }
    });
  }
});
```

### 5.3 Secure Storage Extraction

```bash
# Android: check if flutter_secure_storage uses EncryptedSharedPreferences
adb shell run-as com.fluxonlink.app cat shared_prefs/FlutterSecureStorage.xml

# If using Android Keystore, keys are hardware-backed and not extractable
# without device unlock + root

# iOS: check Keychain (requires jailbreak)
# Use keychain-dumper or objection
objection -g com.fluxonlink.app explore
# ios keychain dump
```

### 5.4 Background Service Security

```bash
# Check if foreground service is running
adb shell dumpsys activity services com.fluxonlink.app

# Monitor BLE activity while app is backgrounded
adb logcat -s flutter,BluetoothGatt

# Verify: does the app continue relaying when backgrounded?
# Verify: is the foreground notification visible? (user awareness)
```

## Phase 6: Physical & Side-Channel

### 6.1 Proximity Tracking

**Goal:** Can a passive observer track a FluxonApp user via BLE?

```
Factors:
- BLE MAC rotation: iOS rotates every ~15 min; Android may not
- Advertising content: if consistent, can fingerprint device
- Service UUID: static, identifiable as FluxonApp
- Timing patterns: regular advertising intervals are trackable
```

**Mitigation assessment:**
- Does the app use BLE privacy features?
- Is advertising interval randomized?
- Can the service UUID be rotated or hidden?

### 6.2 Shoulder Surfing / Screen Capture

**Check:**
- Is the chat screen flagged as secure? (`FLAG_SECURE` on Android)
- Can screenshots be taken of chat content?
- Is the app visible in recent apps with message content?
- Does the group passphrase entry screen mask input?

## Reporting Template

### Finding Format

```
## [SEVERITY] Finding Title

**Category:** BLE / Mesh / Crypto / Mobile / Physical
**CVSS Score:** X.X
**Affected Component:** lib/path/to/file.dart

### Description
What the vulnerability is and how it was discovered.

### Reproduction Steps
1. Step one
2. Step two
3. Observed result

### Impact
What an attacker can achieve by exploiting this.

### Recommendation
How to fix the vulnerability, with code examples if applicable.

### References
- Relevant CWE, CVE, or standard reference
```

### Severity Levels

| Level | Definition | Example |
|---|---|---|
| Critical | Remote code execution, key extraction, auth bypass | Signature verification skip |
| High | Data exposure, session hijack, crypto weakness | Nonce reuse, plaintext key storage |
| Medium | DoS, information leak, privilege escalation | Dedup bypass, BLE connection flood |
| Low | Minor info leak, best practice deviation | Verbose logging, missing FLAG_SECURE |
| Info | Observation, no direct security impact | Service UUID identifiable |

## Testing Checklist

### BLE Layer
- [ ] Advertising data reviewed for information leakage
- [ ] GATT permissions verified (no unauthorized read/write)
- [ ] Packet injection with malformed data tested
- [ ] Connection flooding tested (6+ simultaneous)
- [ ] BLE MAC address rotation verified

### Mesh Protocol
- [ ] Packet replay tested (before and after dedup TTL)
- [ ] TTL manipulation tested (0, max, overflow)
- [ ] Flood attack tested (memory/CPU impact)
- [ ] Topology poisoning tested
- [ ] Gossip sync abuse tested

### Cryptography
- [ ] Noise XX handshake correctness verified
- [ ] Nonce uniqueness verified across messages
- [ ] Signature bypass attempted (zero, wrong key, modified payload)
- [ ] Group key brute-force feasibility assessed
- [ ] Key material not in logs or plaintext storage

### Mobile App
- [ ] APK/IPA static analysis completed
- [ ] Data-at-rest extracted and reviewed
- [ ] Secure storage implementation verified
- [ ] Background service behavior audited
- [ ] Root/jailbreak detection assessed
- [ ] Debug logging disabled in release build

### Physical
- [ ] BLE proximity tracking feasibility assessed
- [ ] Screen capture protection verified
- [ ] Backup extraction (ADB, iTunes) tested
