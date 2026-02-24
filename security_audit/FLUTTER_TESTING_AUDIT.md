# FluxonApp — Flutter Testing Audit Report

> **Audited:** 2026-02-24  
> **Skill used:** `flutter-testing` skill  
> **Test framework:** `flutter_test` + `mocktail` (v1.0.4)  
> **Flutter SDK:** ^3.10.8  

---

## Executive Summary

| Metric | Value |
|---|---|
| **Source files** (lib/) | 66 |
| **Unit/widget test files** (test/) | 43 |
| **Integration test files** (integration_test/) | 1 |
| **Total test cases** | **628** |
| **All passing?** | ✅ Yes (0 failures) |
| **Execution time** | ~32 seconds |
| **Files with dedicated tests** | ~50 / 66 (~76%) |
| **Files with NO tests** | ~16 / 66 (~24%) |

**Overall assessment: GOOD — strong foundation, but meaningful gaps remain in widget/UI tests, provider wiring tests, and edge-case coverage on critical subsystems.**

---

## 1. Source → Test Coverage Map

### ✅ Files WITH Tests

| Source File | Test File(s) | Test Type |
|---|---|---|
| `core/crypto/keys.dart` | `test/core/keys_test.dart` | Unit |
| `core/crypto/noise_session_manager.dart` | `test/core/noise_session_manager_test.dart` | Unit |
| `core/crypto/signatures.dart` | (covered in integration_test + signing tests) | Integration |
| `core/device/device_services.dart` | `test/core/device_services_test.dart` | Unit |
| `core/identity/group_cipher.dart` | `test/core/group_cipher_test.dart` | Unit |
| `core/identity/group_manager.dart` | `test/core/group_manager_test.dart` | Unit |
| `core/identity/group_storage.dart` | `test/core/group_storage_test.dart` | Unit |
| `core/identity/identity_manager.dart` | `test/core/identity_manager_test.dart` | Unit |
| `core/mesh/deduplicator.dart` | `test/core/deduplicator_test.dart` | Unit |
| `core/mesh/gossip_sync.dart` | `test/core/gossip_sync_test.dart` | Unit |
| `core/mesh/mesh_service.dart` | `test/core/mesh_service_test.dart`, `mesh_service_signing_test.dart`, `mesh_relay_integration_test.dart` | Unit + Integration |
| `core/mesh/relay_controller.dart` | `test/core/relay_controller_test.dart` | Unit |
| `core/mesh/topology_tracker.dart` | `test/core/topology_test.dart` | Unit |
| `core/protocol/binary_protocol.dart` | `test/core/binary_protocol_discovery_test.dart`, `test/core/protocol/receipt_codec_test.dart` | Unit |
| `core/protocol/packet.dart` | `test/core/packet_test.dart`, `packet_immutability_test.dart` | Unit |
| `core/services/foreground_service_manager.dart` | `test/core/foreground_service_manager_test.dart` | Unit |
| `core/services/message_storage_service.dart` | `test/services/message_storage_service_test.dart` | Unit |
| `core/services/receipt_service.dart` | `test/core/services/receipt_service_test.dart` | Unit |
| `core/transport/stub_transport.dart` | `test/core/stub_transport_test.dart` | Unit |
| `core/transport/ble_transport.dart` | `test/core/ble_transport_logic_test.dart`, `test/core/duty_cycle_test.dart` | Unit |
| `features/chat/chat_controller.dart` | `test/features/chat_controller_test.dart` | Unit |
| `features/chat/data/chat_repository.dart` | `test/features/chat_repository_test.dart` | Unit |
| `features/chat/data/mesh_chat_repository.dart` | `test/features/chat_repository_test.dart`, `chat_integration_test.dart` | Unit + Integration |
| `features/chat/message_model.dart` | `test/features/message_model_test.dart` | Unit |
| `features/device_terminal/device_terminal_controller.dart` | `test/features/device_terminal_controller_test.dart` | Unit |
| `features/device_terminal/device_terminal_model.dart` | `test/features/device_terminal_model_test.dart` | Unit |
| `features/emergency/emergency_controller.dart` | `test/features/emergency_controller_test.dart` | Unit |
| `features/emergency/data/emergency_repository.dart` | `test/features/emergency_repository_test.dart` | Unit |
| `features/emergency/data/mesh_emergency_repository.dart` | `test/features/emergency_repository_test.dart` | Unit |
| `features/group/create_group_screen.dart` | `test/features/group_screens_test.dart` | Widget |
| `features/group/join_group_screen.dart` | `test/features/group_screens_test.dart` | Widget |
| `features/group/share_group_screen.dart` | `test/features/share_group_screen_test.dart` | Widget |
| `features/location/location_controller.dart` | `test/features/location_controller_test.dart` | Unit |
| `features/location/location_model.dart` | `test/features/location_test.dart` | Unit |
| `features/location/data/mesh_location_repository.dart` | `test/features/mesh_location_repository_test.dart` | Unit |
| `features/location/location_screen.dart` (partial) | `test/features/location_screen_test.dart` | Widget |
| `shared/geo_math.dart` | `test/shared/geo_math_test.dart` | Unit |
| `app.dart` | `test/widget_test.dart`, `test/features/app_lifecycle_test.dart` | Widget |
| Identity signing lifecycle | `test/core/identity_signing_lifecycle_test.dart` | Unit |
| Receipt integration | `test/features/receipt_integration_test.dart` | Integration |
| Chat integration | `test/features/chat_integration_test.dart` | Integration |

### ❌ Files WITHOUT Tests (Gaps)

| Source File | Type | Risk | Notes |
|---|---|---|---|
| `core/crypto/noise_protocol.dart` | Logic | 🔴 **HIGH** | Noise XX handshake, CipherState, SymmetricState — covered only via integration_test (device-only); **no unit-level test** runnable in CI |
| `core/crypto/noise_session.dart` | Logic | 🔴 **HIGH** | Session wrapper for encrypt/decrypt — same integration-only situation |
| `core/crypto/sodium_instance.dart` | Init | 🟡 Medium | Singleton sodium initializer — hard to unit test, acceptable to skip |
| `core/identity/peer_id.dart` | Model | 🟡 Medium | Equality, fromHex, hashCode — used heavily, but no dedicated tests |
| `core/identity/user_profile_manager.dart` | Logic | 🟡 Medium | Display name persistence — no tests for setName edge cases |
| `core/protocol/message_types.dart` | Enum | 🟢 Low | Pure enum — low risk |
| `core/protocol/padding.dart` | Utility | 🟡 Medium | PKCS#7 pad/unpad — security-relevant, no unit tests |
| `core/services/notification_sound.dart` | Service | 🟢 Low | Audio playback — hard to unit-test without platform plugins |
| `core/transport/transport.dart` | Interface | 🟢 Low | Abstract interface — nothing to test |
| `core/transport/transport_config.dart` | Config | 🟢 Low | Data class with defaults — low risk |
| `core/providers/*.dart` (3 files) | Wiring | 🟡 Medium | Provider definitions — no dedicated wiring tests |
| `features/chat/chat_providers.dart` | Wiring | 🟡 Medium | Provider graph — no wiring validation tests |
| `features/chat/chat_screen.dart` | Widget | 🔴 **HIGH** | Primary UI screen — **no widget tests at all** |
| `features/emergency/emergency_screen.dart` | Widget | 🔴 **HIGH** | SOS UI — **no widget tests** |
| `features/emergency/emergency_providers.dart` | Wiring | 🟡 Medium | No wiring tests |
| `features/device_terminal/device_terminal_screen.dart` | Widget | 🟡 Medium | Terminal UI — no widget tests |
| `features/device_terminal/device_terminal_providers.dart` | Wiring | 🟢 Low | Provider wiring |
| `features/device_terminal/data/ble_device_terminal_repository.dart` | BLE | 🟡 Medium | Concrete BLE implementation — hard to unit test without platform |
| `features/location/location_providers.dart` | Wiring | 🟢 Low | Provider wiring |
| `features/onboarding/onboarding_screen.dart` | Widget | 🟡 Medium | First-run screen — no widget tests |
| `shared/compression.dart` | Utility | 🟡 Medium | zlib compress/decompress & zip-bomb protection — no tests |
| `shared/hex_utils.dart` | Utility | 🟡 Medium | Encode/decode hex — implicitly tested, no dedicated tests |
| `shared/logger.dart` | Utility | 🟢 Low | Logging wrapper — low risk |
| `main.dart` | Bootstrap | 🟢 Low | App entry point — tested via widget_test.dart partially |

---

## 2. Test Quality Analysis

### 2.1 Unit Tests — Strong ✅

**Strengths:**
- Clean **Arrange–Act–Assert** pattern throughout
- Excellent use of **mocktail** for dependency isolation
- Repository pattern makes controllers highly testable
- Controllers tested via `StateNotifier` state transitions
- Good edge-case coverage (e.g., deduplicator expiry, topology freshness, TTL capping)
- Proper `setUp`/`tearDown` patterns — tests are independent

**Weaknesses:**
- Some test files are very large (e.g., `chat_repository_test.dart` at 24KB, `mesh_service_test.dart` at 22KB) — consider splitting by concern
- Missing negative/error path tests in some controllers (e.g., what happens if `_persistMessages()` throws)
- No tests for `ChatState.copyWith()` or `LocationState.copyWith()` in isolation

### 2.2 Widget Tests — Moderate ⚠️

**Strengths:**
- Group screens (`CreateGroupScreen`, `JoinGroupScreen`, `ShareGroupScreen`) have thorough widget tests
- `LocationScreen` has basic widget tests
- `FluxonApp` root widget is tested for nav bar rendering

**Critical Gaps:**
- **`ChatScreen` — ZERO widget tests.** This is the primary user-facing screen.
- **`EmergencyScreen` — ZERO widget tests.** SOS is safety-critical.
- **`DeviceTerminalScreen` — ZERO widget tests.**
- **`OnboardingScreen` — ZERO widget tests.** (first-run experience)
- No tests for navigation between screens (bottom nav switching)
- No orientation/responsive layout tests for any screen

### 2.3 Integration Tests — Good but Limited ✅

**Strengths:**
- `integration_test/crypto_on_device_test.dart` is comprehensive (1546 lines!) covering Noise protocol, session manager, E2E handshakes, signatures, and mesh service signing
- Uses `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` correctly
- Covers the critical crypto stack that can't run outside a device

**Weaknesses:**
- **Only 1 integration test file** — focused entirely on crypto
- No end-to-end user flow integration tests (e.g., onboarding → create group → send message)
- No navigation integration tests
- The crypto tests in `integration_test/` duplicate test logic from `test/core/` — this was intentional (crypto needs real sodium), but the duplication increases maintenance cost

### 2.4 Mocking Approach — Excellent ✅

- Consistent use of `mocktail` throughout
- `Transport`, `ChatRepository`, `LocationRepository`, `EmergencyRepository`, `DeviceTerminalRepository` — all properly abstracted behind interfaces
- `GpsService` and `PermissionService` are mockable via DIP
- `GroupManager` uses concrete instances in tests (acceptable since it's in-memory)
- `FlutterSecureStorage` mocking follows platform channel mocking pattern

### 2.5 Test Naming — Good ✅

- Descriptive names: `"ChatController – sends a message and appends it to state"`
- `group()` blocks organize tests logically
- Could improve by using "should" convention more consistently

---

## 3. Risk Assessment by Subsystem

| Subsystem | Unit Tests | Widget Tests | Integration Tests | Overall Risk |
|---|---|---|---|---|
| **Crypto (Noise/Keys/Signatures)** | ⚠️ CI-only stubs | N/A | ✅ Device tests | 🟡 Medium — CI blind spot |
| **Identity (PeerId, Groups, Trust)** | ✅ Solid | N/A | ✅ | 🟢 Low |
| **Mesh (Relay, Topology, Gossip, Dedup)** | ✅ Excellent | N/A | ✅ Partial | 🟢 Low |
| **Protocol (Packet, Binary, Padding)** | ✅ Good | N/A | N/A | 🟡 Medium — padding untested |
| **Transport (BLE, Stub)** | ✅ Good | N/A | N/A | 🟢 Low |
| **Chat Feature** | ✅ Controller + Repo | ❌ No screen tests | ✅ Integration | 🔴 **HIGH** — missing UI tests |
| **Location Feature** | ✅ Controller + Repo | ⚠️ Basic screen | N/A | 🟡 Medium |
| **Emergency Feature** | ✅ Controller + Repo | ❌ No screen tests | N/A | 🔴 **HIGH** — safety-critical |
| **Device Terminal** | ✅ Controller + Model | ❌ No screen tests | N/A | 🟡 Medium |
| **Group Feature** | ✅ Model + Storage | ✅ Widget tests | N/A | 🟢 Low |
| **Onboarding** | ❌ None | ❌ None | N/A | 🟡 Medium |
| **Shared Utilities** | ⚠️ Only geo_math | N/A | N/A | 🟡 Medium |

---

## 4. Prioritized Recommendations

### 🔴 P0 — Critical (Fix First)

#### 4.1 Add `ChatScreen` Widget Tests
The chat screen is the primary UI surface. Test:
- Message list rendering (empty state, with messages)
- Text input & send button interaction
- Received message display (sender name, timestamp, status indicators)
- Message deletion (individual + clear all)
- Scroll behavior and auto-scroll on new message

```dart
// Example pattern from the skill guide:
testWidgets('ChatScreen displays messages', (tester) async {
  // Override providers with mocks
  await tester.pumpWidget(ProviderScope(
    overrides: [/* mock transport, peerId, groupManager, etc. */],
    child: const MaterialApp(home: ChatScreen()),
  ));
  await tester.pumpAndSettle();
  
  expect(find.byType(ListView), findsOneWidget);
});
```

#### 4.2 Add `EmergencyScreen` Widget Tests
SOS is safety-critical — the "Send SOS" button and retry flow must be tested:
- SOS button renders and is tappable
- Alert type selection works
- Error state shows retry button
- Received alerts render in the list
- Location data is displayed

#### 4.3 Add Unit Tests for `PeerId`
`PeerId` is used throughout the entire codebase — equality, `fromHex`, `hashCode`, and `broadcast` should be exhaustively tested.

```dart
test('PeerId equality', () {
  final a = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
  final b = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
  expect(a, equals(b));
  expect(a.hashCode, equals(b.hashCode));
});

test('PeerId.fromHex rejects wrong length', () {
  expect(() => PeerId.fromHex('aabb'), throwsFormatException);
});
```

### 🟡 P1 — Important (Fix Soon)

#### 4.4 Add `MessagePadding` Unit Tests
PKCS#7 is security-relevant. Test:
- Round-trip `pad` → `unpad`
- `unpad` returns `null` for invalid padding
- `unpad` returns `null` for empty data
- Different block sizes
- Data that's already a multiple of block size

#### 4.5 Add `Compression` Unit Tests
Zip bomb protection (`maxOutputSize`) must be tested:
- Round-trip compress → decompress
- Decompress with exceeded `maxOutputSize` returns `null`
- Decompress invalid data returns `null`

#### 4.6 Add `HexUtils` Unit Tests
- Encode/decode round-trip
- Edge cases: empty bytes, odd-length hex string
- Known test vectors

#### 4.7 Add `UserProfileManager` Unit Tests
- `setName` trims whitespace
- `setName` enforces 32-char limit
- `setName('')` clears the name
- `hasName` returns false when empty

#### 4.8 Add `OnboardingScreen` Widget Tests
First-run experience should be tested:
- Name input field renders
- Submit button validates non-empty name
- Navigates to home screen after submission

#### 4.9 Add `DeviceTerminalScreen` Widget Tests
- Scan button renders
- Device list populates
- Connection flow UI states (scanning → connecting → connected)

### 🟢 P2 — Nice to Have

#### 4.10 Add Navigation Integration Tests
Test bottom navigation switching between Chat, Map, SOS, and Device tabs.

#### 4.11 Add Provider Wiring Tests
Validate that the Riverpod provider graph correctly resolves:
```dart
test('chatControllerProvider resolves without throwing', () {
  final container = ProviderContainer(overrides: [
    transportProvider.overrideWithValue(mockTransport),
    myPeerIdProvider.overrideWithValue(mockPeerId),
    groupManagerProvider.overrideWithValue(GroupManager()),
    displayNameProvider.overrideWith((ref) => 'Test'),
  ]);
  expect(() => container.read(chatControllerProvider), returnsNormally);
});
```

#### 4.12 Add End-to-End User Flow Integration Test
Test the complete flow: launch app → onboarding → create group → send message → receive message.

#### 4.13 Split Large Test Files
`chat_repository_test.dart` (24KB) and `mesh_service_test.dart` (22KB) should be split into focused test files grouped by behavior.

#### 4.14 Run Tests with Coverage
```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
```
This will provide exact line-level coverage metrics to guide future testing efforts.

---

## 5. Testing Best Practices Checklist

| Practice | Status | Notes |
|---|---|---|
| **Test Pyramid** (more unit, fewer integration) | ✅ | 43 unit/widget files vs 1 integration file |
| **Descriptive test names** | ✅ | Clear and consistent |
| **Arrange–Act–Assert** | ✅ | Followed throughout |
| **Test independence** | ✅ | Each test stands alone |
| **Mock external dependencies** | ✅ | Excellent use of mocktail |
| **Run tests in CI** | ⚠️ | Not verified — crypto tests require a device |
| **Widget tests for all screens** | ❌ | 3 of 7 screens tested |
| **Edge-case coverage** | ⚠️ | Good in core, missing in shared utils |
| **Error path testing** | ⚠️ | Some controllers missing error scenarios |
| **Performance tests** | ❌ | No scrolling/rendering perf tests |
| **Orientation tests** | ❌ | No landscape mode tests |

---

## 6. Test Infrastructure Health

### Dependencies ✅
- `flutter_test` (SDK) — up to date
- `integration_test` (SDK) — up to date
- `mocktail: ^1.0.4` — appropriate choice (no codegen required)
- No `build_runner` or `mockito` codegen dependency — keeps test execution fast

### Test Execution ✅
- All 628 tests pass in ~32 seconds
- No flaky tests detected
- Minor warning: `ClientException` from OSM tile requests during `widget_test.dart` — these are non-blocking network requests from `flutter_map` but should be mocked to eliminate noise

### File Organization ✅
- Tests mirror `lib/` structure (`test/core/`, `test/features/`, `test/shared/`, `test/services/`)
- Integration tests in `integration_test/`
- Consistent naming: `*_test.dart` suffix

---

## 7. Summary Action Items

| Priority | Action | Effort | Impact |
|---|---|---|---|
| 🔴 P0 | Widget tests for `ChatScreen` | Medium | High — primary UI |
| 🔴 P0 | Widget tests for `EmergencyScreen` | Medium | High — safety-critical |
| 🔴 P0 | Unit tests for `PeerId` | Low | High — foundational model |
| 🟡 P1 | Unit tests for `MessagePadding` | Low | Medium — crypto utility |
| 🟡 P1 | Unit tests for `Compression` | Low | Medium — security (zip bomb) |
| 🟡 P1 | Unit tests for `HexUtils` | Low | Medium — widely used |
| 🟡 P1 | Unit tests for `UserProfileManager` | Low | Medium — persistence |
| 🟡 P1 | Widget tests for `OnboardingScreen` | Medium | Medium — first impressions |
| 🟡 P1 | Widget tests for `DeviceTerminalScreen` | Medium | Medium |
| 🟢 P2 | Navigation integration tests | Medium | Low |
| 🟢 P2 | Provider wiring validation tests | Low | Low |
| 🟢 P2 | E2E user flow integration test | High | Medium |
| 🟢 P2 | Coverage report generation | Low | Medium — visibility |
| 🟢 P2 | Mock OSM tile requests in widget_test | Low | Low — noise reduction |

---

*Report generated using the `flutter-testing` skill guidelines, covering unit, widget, and integration test analysis per the Flutter testing pyramid.*
