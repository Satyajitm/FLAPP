# FluxonApp — Changelog

All notable changes to FluxonApp are documented here, organized by version and phase.
Each entry records **what** changed, **which files** were affected, and **why** the decision was made.

---

## [v2.3] — Incoming Message Notification Sound
**Date:** 2026-02-20
**Branch:** `v2`

### Summary
Added an audible notification tone when an incoming (non-local) chat message is received. The tone is a short two-note chime (880 Hz → 1047 Hz, 200ms) generated programmatically at runtime — no bundled audio assets required.

---

### Changes

#### 1. `audioplayers` Dependency — `pubspec.yaml`

**What changed:**
- Added `audioplayers: ^6.1.0`

**Why:**
Provides cross-platform audio playback (Android, iOS, desktop) from a local file source. Used to play the generated notification WAV.

---

#### 2. Notification Sound Service — `lib/core/services/notification_sound.dart` *(new)*

**What changed:**
- New `NotificationSoundService` class
- `play()` — generates a WAV file on first call (cached in temp directory), then plays it via `AudioPlayer`
- `_generateToneWav()` — builds a 200ms, 16-bit mono, 44100 Hz WAV in memory: two-tone sine wave (A5 → C6) with 5ms fade-in/fade-out envelope to avoid clicks
- `dispose()` — releases the `AudioPlayer` resource

**Why:**
Generating the tone at runtime avoids bundling audio assets and keeps the app size minimal. The two-tone chime is short and distinctive without being jarring. The file is cached in the temp directory so it's only generated once per app session.

---

#### 3. Chat Screen Listener — `lib/features/chat/chat_screen.dart`

**What changed:**
- Added `import '../../core/services/notification_sound.dart'` and `import 'chat_controller.dart'`
- Added `_notificationSound` field (`NotificationSoundService` instance) to `_ChatScreenState`
- Added `_notificationSound.dispose()` in `dispose()`
- Added `ref.listen<ChatState>()` in `build()` — compares previous and next message lists; when a new non-local message arrives (`!newest.isLocal`), calls `_notificationSound.play()`

**Why:**
`ref.listen` fires on every state change but only triggers the sound when the message count increases and the newest message is from a remote peer. This avoids playing sounds for the user's own sent messages.

---

### What Did NOT Change
- All of `lib/core/` (transport, mesh, crypto, protocol, identity) — **unchanged**
- Chat controller, repository, model — **unchanged**
- Location, Emergency features — **unchanged**
- Wire protocol, BLE UUIDs, packet format — **unchanged**
- Group management, onboarding, user profiles — **unchanged**

---

## [v2.2] — Bug Fixes: Map + Reactive Group State
**Date:** 2026-02-18
**Branch:** `v2`

### Summary
Fixed three bugs: blank map canvas (missing INTERNET permission + null tile provider fallback), user's own location pin not appearing on the map, and the "Join your group" screen persisting after creating/joining a group (non-reactive GroupManager state).

---

### Changes

#### 1. INTERNET Permission — `android/app/src/main/AndroidManifest.xml`

**What changed:**
- Added `<uses-permission android:name="android.permission.INTERNET" />`

**Why:**
OpenStreetMap tiles are fetched over HTTPS. Without this permission, Android silently blocks all network requests, resulting in a blank map canvas.

---

#### 2. Tile Provider Fallback — `lib/features/location/location_screen.dart`

**What changed:**
- `TileLayer.tileProvider` now uses `_tileProvider ?? NetworkTileProvider()` instead of passing `_tileProvider` directly
- When the async disk cache (`CachedTileProvider`) hasn't initialized yet or fails silently, tiles are still fetched via the network

**Why:**
Passing `null` to `tileProvider` does not trigger a fallback — it disables tile loading entirely. On first render `_tileProvider` is always `null` (async init), so tiles never appeared.

---

#### 3. Own Location Pin — `lib/features/location/location_screen.dart`

**What changed:**
- `_buildMarkers()` now includes the user's own location (`myLocation`) as a green `Icons.my_location` marker, in addition to group members' blue `Icons.person_pin_circle` markers

**Why:**
`myLocation` was stored in a separate field from `memberLocations` but was never rendered on the map.

---

#### 4. Default Map Center — `lib/features/location/location_screen.dart`

**What changed:**
- `MapOptions.initialCenter` changed from `LatLng(0, 0)` to `LatLng(20.5937, 78.9629)` (India)
- `MapOptions.initialZoom` changed from `15` to `5`

**Why:**
`LatLng(0, 0)` at zoom 15 shows open ocean (Gulf of Guinea). Centering on India at country-level zoom provides a meaningful initial view.

---

#### 5. Reactive Group State — `lib/core/providers/group_providers.dart`

**What changed:**
- Added `activeGroupProvider` — a `StateProvider<FluxonGroup?>` that tracks the currently active group reactively
- Seeded from `GroupManager.activeGroup` (covers groups restored from storage on startup)

**Why:**
`GroupManager` is a plain Dart class. When `createGroup()` / `joinGroup()` / `leaveGroup()` mutated its internal `_activeGroup`, Riverpod had no way to detect the change, so `ChatScreen` never rebuilt — it stayed stuck on the "Join your group" page forever.

---

#### 6. Create/Join Screens Update Reactive State

**Files:** `lib/features/group/create_group_screen.dart`, `lib/features/group/join_group_screen.dart`

**What changed:**
- After calling `groupManager.createGroup()` / `joinGroup()`, both screens now also set `ref.read(activeGroupProvider.notifier).state = group`

**Why:**
Bridges the gap between the imperative `GroupManager` mutation and Riverpod's reactive state system.

---

#### 7. Chat Screen Watches Reactive Provider — `lib/features/chat/chat_screen.dart`

**What changed:**
- `build()` now watches `activeGroupProvider` instead of reading `groupManager.activeGroup`
- Leave Group action in the bottom sheet now clears `activeGroupProvider` in addition to calling `groupManager.leaveGroup()`
- Removed unused `groupManager` local variable from `_showGroupMenu()`

**Why:**
Watching the reactive `StateProvider` ensures the UI rebuilds when group state changes (create, join, leave).

---

### What Did NOT Change
- All of `lib/core/` (transport, mesh, crypto, Noise protocol, identity) — **unchanged**
- `GroupManager`, `GroupCipher`, `GroupStorage` — **unchanged** (reactive wrapper added around them, not inside them)
- Wire protocol, BLE UUIDs, packet format — **unchanged**
- Chat, Location, Emergency repositories and controllers — **unchanged**
- Onboarding, user profile — **unchanged**

---

## [v2.1] — Phase 4 (continued): User Display Name + Onboarding
**Date:** 2026-02-17
**Branch:** `phase_4`
**Tests:** 92 feature tests passing
**Analyzer:** 0 errors

### Summary
Added user identity via a display name: first-run onboarding asks for the user's name, which is persisted in secure storage and distributed in every chat message payload. Remote peers see the sender's name in message bubbles instead of the cryptographic shortId. Users can change their name at any time from the group menu.

No transport, crypto, mesh, or group management code was changed.

---

### Changes

#### 1. User Profile Storage — `lib/core/identity/user_profile_manager.dart` *(new)*

**What changed:**
- New `UserProfileManager` class — loads/saves `user_display_name` via `flutter_secure_storage`
- `initialize()` — loads persisted name on startup
- `setName(String)` — persists trimmed name; deletes key if empty

**Why:**
Dedicated class keeps naming concerns separate from cryptographic identity (`IdentityManager`) and group membership (`GroupManager`).

---

#### 2. Profile Providers — `lib/core/providers/profile_providers.dart` *(new)*

**What changed:**
- `userProfileManagerProvider` — `Provider<UserProfileManager>`, overridden in `main.dart`
- `displayNameProvider` — `StateProvider<String>`, overridden in `main.dart` with loaded name; updates reactively when the user changes their name at runtime

**Why:**
`StateProvider` allows the onboarding screen and name-change dialog to update the state in one place and have the entire widget tree rebuild automatically (including `FluxonApp`'s home switch).

---

#### 3. Chat Payload Format — `lib/core/protocol/binary_protocol.dart`

**What changed:**
- New `ChatPayload` class with `senderName` and `text` fields
- `encodeChatPayload(text, {senderName})` — when `senderName` is non-empty, encodes as compact JSON `{"n":"Alice","t":"Hello"}` (UTF-8); empty name = plain UTF-8 (legacy format unchanged)
- `decodeChatPayload(Uint8List)` now returns `ChatPayload` instead of `String`; detects JSON format via `{"n":` prefix with fallback to plain-text

**Why:**
Attaching the name to each message packet is the simplest way to propagate names across the mesh without a separate announcement protocol. The JSON detection scheme maintains backward compatibility with legacy plain-text messages.

---

#### 4. `ChatMessage` Model — `lib/features/chat/message_model.dart`

**What changed:**
- Added `senderName` field (`String`, default `''`)

---

#### 5. `ChatRepository` Interface — `lib/features/chat/data/chat_repository.dart`

**What changed:**
- Added optional `senderName` parameter to `sendMessage()`

---

#### 6. `MeshChatRepository` — `lib/features/chat/data/mesh_chat_repository.dart`

**What changed:**
- `sendMessage()` accepts `senderName` and passes it to `encodeChatPayload()`
- `_handleIncomingPacket()` calls updated `decodeChatPayload()` and extracts `senderName` onto the `ChatMessage`
- Local `ChatMessage` returned from `sendMessage()` also carries `senderName`

---

#### 7. `ChatController` — `lib/features/chat/chat_controller.dart`

**What changed:**
- Added `String Function() getDisplayName` constructor parameter (callback evaluated at send time)
- `sendMessage()` passes `getDisplayName()` result as `senderName` to the repository

**Why:**
Using a callback rather than a captured value means name changes take effect immediately on the next message, without recreating the controller.

---

#### 8. `chat_providers.dart` — `lib/features/chat/chat_providers.dart`

**What changed:**
- Imports `profile_providers.dart`
- Passes `getDisplayName: () => ref.read(displayNameProvider)` when constructing `ChatController`

---

#### 9. Onboarding Screen — `lib/features/onboarding/onboarding_screen.dart` *(new)*

**What changed:**
- Hero icon (`Icons.person_outline`) in `primaryContainer` circle (88×88 px)
- "Welcome to FluxonApp" heading + subtitle
- Single `TextField` with `autofocus` for name entry
- `FilledButton` "Let's go" — awaits `UserProfileManager.setName()`, then sets `displayNameProvider` state, triggering `FluxonApp` rebuild

---

#### 10. `app.dart` — `lib/app.dart`

**What changed:**
- `FluxonApp` changed from `StatelessWidget` to `ConsumerWidget`
- Watches `displayNameProvider`; renders `OnboardingScreen` when `displayName.isEmpty`, otherwise `_HomeScreen`

**Why:**
Reactive provider-driven routing avoids manual navigation — the root widget simply rebuilds when the name is set.

---

#### 11. `chat_screen.dart` — `lib/features/chat/chat_screen.dart`

**What changed:**
- `_MessageBubble` shows `message.senderName` for remote messages (falls back to `sender.shortId` if empty)
- `_showGroupMenu()` now shows a "Your name" `ListTile` at the top — displays current name and navigates to `_showChangeNameDialog()`
- New `_showChangeNameDialog()` — `AlertDialog` with pre-filled `TextField`; on save, calls `UserProfileManager.setName()` and updates `displayNameProvider`
- New `_commitNameChange()` helper

---

#### 12. `main.dart` — `lib/main.dart`

**What changed:**
- Imports `UserProfileManager` and `profile_providers`
- `UserProfileManager()` initialized and `await profileManager.initialize()` called before `runApp`
- `ProviderScope` overrides include `userProfileManagerProvider` and `displayNameProvider`

---

### Test Updates

**`test/features/chat_controller_test.dart`**
- `FakeChatRepository.sendMessage()` updated to accept `senderName` parameter
- `ChatController` constructor updated with `getDisplayName: () => 'TestUser'`

**`test/features/chat_repository_test.dart`**
- Two assertions that compared `BinaryProtocol.decodeChatPayload(...)` directly to a `String` updated to access `.text` on the returned `ChatPayload`

**`test/features/app_lifecycle_test.dart`**
- `_buildApp()` helper updated to override `userProfileManagerProvider` and `displayNameProvider` (with `'Tester'` so `_HomeScreen` renders)

---

### What Did NOT Change
- All of `lib/core/` — transport, mesh, crypto, Noise protocol: **unchanged**
- `GroupManager`, `GroupStorage`, `GroupCipher` — **unchanged**
- Wire packet header format — **unchanged** (only the payload encoding changed for chat type)
- Location, Emergency features — **unchanged**

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
