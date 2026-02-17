# FluxonApp — Changelog

All notable changes to FluxonApp are documented here, organized by version and phase.
Each entry records **what** changed, **which files** were affected, and **why** the decision was made.

---

## [v2.0] — Phase 4: UI Redesign + Private Chat Removal
**Date:** 2026-02-17
**Branch:** `phase_4`
**Tests:** All feature tests passing (group screens ×15, chat controller ×7)
**Analyzer:** 0 errors

### Summary
Phase 4 removed the one-to-one private (direct) messaging feature from the UI entirely — FluxonApp is a group-only communication tool. Simultaneously, all four affected screens received a clean minimal redesign: spacious layout, rounded components, Material 3 color roles, and directional message bubbles.

No backend, crypto, transport, or protocol code was changed.

---

### Changes

#### 1. Remove Private/Direct Messaging — `lib/features/chat/chat_controller.dart`

**What changed:**
- Removed `selectedPeer` field from `ChatState`
- Removed `selectedPeer` parameter from `ChatState.copyWith()`
- Removed the `_sentinel` object pattern used to distinguish "no peer selected" from `null`
- Removed `selectPeer(PeerId? peer)` method from `ChatController`
- `sendMessage()` now always calls `_repository.sendMessage()` (group broadcast). It never calls `sendPrivateMessage()`.

**Why:**
FluxonApp is explicitly a group communication tool. One-to-one private messaging was implemented at the protocol level (Noise XX encrypted sessions, `MessageType.noiseEncrypted`) but was never a product feature — it added UI complexity without serving the core use case. Removing it from the controller simplifies state management and prevents accidental misuse.

**Note:** `ChatRepository.sendPrivateMessage()` is retained at the interface/implementation level. The protocol capability exists; it is simply not exposed via the UI.

---

#### 2. Chat Screen Redesign — `lib/features/chat/chat_screen.dart`

**What changed:**

*Removed:*
- `_showPeerPicker()` — bottom sheet for selecting a private message recipient
- `_buildPeerSelector()` — the peer-selector chip bar shown above the input when a peer was selected
- `_PeerPickerSheet` — entire widget class (~65 lines) for the private peer picker sheet
- `person_add` `IconButton` in the input bar (triggered peer picker)
- `selectedPeer` parameter from `_buildInputBar()`

*Added / Redesigned:*
- **AppBar**: Reads `groupManagerProvider`. When in a group shows `group.name` in bold + `'$memberCount member(s)'` or `'Mesh active'` (if count is 0) in primary-color caption. When not in a group shows `'No Group'` in muted style. Group management actions moved to `Icons.more_vert` → bottom sheet.
- **Group menu (bottom sheet)**: Accessed via `Icons.more_vert`. Contains Create Group, Join Group, and Leave Group (red, shown only when `groupManager.isInGroup`).
- **No-group state** (`_buildNoGroupState()`): Hero icon (`Icons.hub_outlined`) in a `primaryContainer` circle, "Join your group" heading, subtitle, `FilledButton` "Create Group" + `OutlinedButton` "Join Group" CTAs. Replaces the old grey placeholder text.
- **In-group empty state** (`_buildEmptyMessagesState()`): Centered `chat_bubble_outline` icon + "No messages yet" + "Say hello to your group!" subtitle.
- **Message bubbles** (`_MessageBubble`): Directional `BorderRadius` (sharp corner on the sender's side, rounded elsewhere). Local messages: `colorScheme.primary` fill, white text. Remote messages: `colorScheme.surfaceContainerLow` fill + thin `outlineVariant` border. Sender shortId shown in monospace caption on remote bubbles. Timestamp in muted caption aligned bottom-right.
- **Input bar**: Pill-shaped `TextField` (`BorderRadius.circular(24)`) with `AnimatedSwitcher` between send icon and `CircularProgressIndicator` when sending. No private-message icon.

**Why:**
The old screen mixed group and private messaging UI, making the product story confusing. The redesign reinforces the single mental model (you are in a group, you broadcast to the group). The no-group CTA state makes onboarding obvious. Directional bubbles and the cleaner input bar are standard modern messaging conventions.

---

#### 3. Create Group Screen Redesign — `lib/features/group/create_group_screen.dart`

**What changed:**
Full rewrite of the widget tree. Previous version had a basic `Column` with two text fields and a button. New version:
- Hero icon (`Icons.hub_outlined`) in a `primaryContainer` coloured circle (72×72 px)
- "Create a group" heading (22px bold) + centered subtitle
- Group Name `TextField` with `group_outlined` prefix icon, "Optional" helper text, `BorderRadius.circular(12)`
- Passphrase `TextField` with lock icon, visibility toggle suffix icon, helper text
- Full-height `FilledButton` ("Create Group") with `BorderRadius.circular(12)` and 52px minimum height

**Why:**
The old screen had no visual hierarchy. The hero icon establishes context immediately. The layout follows the same pattern as Join Group, creating visual consistency across the onboarding flow.

---

#### 4. Join Group Screen Redesign — `lib/features/group/join_group_screen.dart`

**What changed:**
Full rewrite. Previous version was a minimal scaffold. New version:
- Hero icon (`Icons.login_outlined`) in a `secondaryContainer` coloured circle (72×72 px) — different colour from Create Group to differentiate the two actions
- "Join a group" heading + centered subtitle explaining the passphrase
- Passphrase `TextField` with obscure toggle, lock icon prefix
- `_isJoining` loading state — disables button and shows `CircularProgressIndicator` while join operation runs
- Full-height `FilledButton` ("Join Group")

**Why:**
Same reasoning as Create Group — visual hierarchy and consistency. The `secondaryContainer` circle differentiates "join" from "create" at a glance. The loading state prevents double-taps.

---

#### 5. App Theme — `lib/app.dart`

**What changed:**
- Added `appBarTheme` to both `theme` and `darkTheme`:
  - `centerTitle: false` (left-aligned titles)
  - `elevation: 0`, `scrolledUnderElevation: 0` (flat app bars)
- Added `navigationBarTheme`:
  - `elevation: 0` (flat nav bar)
  - `labelBehavior: NavigationDestinationLabelBehavior.alwaysShow`

**Why:**
Material 3 defaults include subtle elevation overlays that feel slightly dated. Zero elevation matches the clean minimal aesthetic. These are global defaults so individual screens don't need to repeat them.

---

### Test Updates

#### `test/features/chat_controller_test.dart`

**What changed:**
Replaced 3 obsolete tests that tested the removed private-chat state:
- `'selectPeer sets selectedPeer'`
- `'selectPeer(null) clears selectedPeer'`
- `'copyWith preserves selectedPeer when other fields change'`

With one new test:
- `'copyWith preserves messages when only isSending changes'`

**Why:** The removed tests referenced `ChatController.selectPeer()` and `ChatState.selectedPeer`, both of which no longer exist. The replacement test validates the `copyWith` pattern still works correctly for the remaining fields.

#### `test/features/group_screens_test.dart`

**What changed:**
Updated all widget finders to match the new screen UI text and button labels:

| Old finder | New finder |
|---|---|
| `find.text('Create a new Fluxon group')` | `find.text('Create a group')` |
| `find.text('Create Group'), findsWidgets` | `find.text('Create Group'), findsOneWidget` |
| `find.byIcon(Icons.add)` (to tap create button) | `find.text('Create Group')` |
| `find.text('Join an existing group')` | `find.text('Join a group')` |
| `find.text('Join Group'), findsWidgets` | `find.text('Join Group'), findsOneWidget` |
| `find.byIcon(Icons.login)` (to tap join button) | `find.text('Join Group')` |
| `find.byIcon(Icons.login), findsOneWidget` (render assertion) | *(removed — no standalone login icon widget)* |

**Why:** The redesigned screens changed heading text, button labels, and the icons used. Tests must mirror the actual UI to remain meaningful.

---

### What Did NOT Change
- All of `lib/core/` — transport, mesh, crypto, identity, protocol: **unchanged**
- `chat_providers.dart`, `message_model.dart` — **unchanged**
- `chat_repository.dart`, `mesh_chat_repository.dart` — **unchanged** (including `sendPrivateMessage()` at the repository level)
- Location, Emergency features — **unchanged**
- Wire protocol, BLE UUIDs, packet format — **unchanged**

---

## [v1.3] — Phase 3: End-to-End Encryption + Private Chat
**Date:** Pre 2026-02-17
**Branch:** `phase_3`
**Tests:** 347 passing

### Summary
- Implemented Ed25519 signing key distribution via Noise handshake messages
- Implemented signature verification in `MeshService._onPacketReceived()`
- Added `MessageType.noiseEncrypted` (0x09) for direct Noise-session encrypted messages
- Added `sendPrivateMessage()` to `ChatRepository` / `MeshChatRepository`
- Added peer selector UI to `ChatScreen` (lock icon, peer chip bar, `_PeerPickerSheet`)
- Fixed all-zeros peerId emission bug (removed pre-handshake `_emitPeerUpdate()` call)

See [PHASE3_PROGRESS.md](PHASE3_PROGRESS.md) for full details.

---

## [v1.2] — Phase 2: Mesh Relay + Group Encryption
**Date:** Pre Phase 3
**Branch:** `phase_2`

### Summary
- Implemented multi-hop relay in `MeshService` (flood + dedup + TTL)
- Added `GroupManager`, `GroupCipher`, `GroupStorage`
- Added group passphrase UI (`CreateGroupScreen`, `JoinGroupScreen`)
- Group-encrypted location sharing in `MeshLocationRepository`

See [PHASE2_DEVICE_VERIFICATION.md](phasewise_verification/PHASE2_DEVICE_VERIFICATION.md) for verification.

---

## [v1.1] — Phase 1: Core Infrastructure
**Date:** Pre Phase 2

### Summary
- Abstract `Transport` interface + `BleTransport` (central + peripheral dual-role BLE)
- `StubTransport` for tests
- `MeshService` skeleton
- Clean Architecture feature slices: Chat, Location, Emergency
- Riverpod provider graph + `ProviderScope` override pattern
- Binary packet format (`FluxonPacket` encoder/decoder)
- `PeerId` derivation (SHA-256 of Ed25519 pubkey)

---

## Versioning Convention

| Label | Meaning |
|---|---|
| `vX.0` | Major product milestone (new architecture or product capability) |
| `vX.Y` | Feature phase completion within a major version |
| Branch naming | `phase_N` corresponds to the development phase |

Pre-existing test suite failures (not caused by any phase's changes):
- `ble_transport_handshake_test.dart`, `noise_test.dart`, `identity_manager_test.dart` — require native libsodium binary; fail on desktop CI
- `location_screen_test.dart` — OSM tile requests return HTTP 400 in offline test environments
