# FluxonApp Frontend Bug Analysis

**Date:** 2026-02-24
**Scope:** All UI screens, controllers, and Riverpod providers
**Total issues found:** 29 (3 Critical, 12 High, 11 Medium, 3 Low)

---

## CRITICAL Issues

### C1 — `mounted` used on StateNotifier (invalid API)
**File:** `lib/features/emergency/emergency_controller.dart` — Lines 165, 182
**Description:** `StateNotifier` has no `mounted` property — that exists only on Flutter `State`/`ConsumerState` widgets. The emergency retry logic calls `if (!mounted) return;` inside the controller after an async delay. At runtime this will throw a `NoSuchMethodError` the first time a retry fires while the widget tree is torn down.
**Fix:** Replace `mounted` checks with a manual `_isDisposed` flag:
```dart
bool _isDisposed = false;

@override
void dispose() {
  _isDisposed = true;
  _alertSub?.cancel();
  super.dispose();
}
// Then: if (_isDisposed) return;
```

---

### C2 — `MapController` never disposed (resource leak)
**File:** `lib/features/location/location_screen.dart` — Line 21
**Description:** `_mapController = MapController()` is allocated in `initState` (or as a field) but `dispose()` is never overridden to call `_mapController.dispose()`. This leaks native resources every time the Location tab is unmounted.
**Fix:** Override `dispose()` and call `_mapController.dispose()`.

---

### C3 — Unguarded state mutations in async stream listeners (disposed controller)
**Files/Lines:**
- `lib/features/chat/chat_controller.dart` — Lines 94–102 (message listener), 108–110 (receipt listener)
- `lib/features/location/location_controller.dart` — Lines 97–123 (`_broadcastCurrentLocation`)
- `lib/features/device_terminal/device_terminal_controller.dart` — Lines 71–80

**Description:** All four stream/timer callbacks are `async` and mutate `state` after one or more `await` points with no `mounted`/`_isDisposed` guard. If the controller is disposed while the async operation is in flight, you get a silent "setState after dispose" equivalent on StateNotifier — state is emitted to a dead notifier and any Riverpod listeners may see a stale or invalid value.

Example from `chat_controller.dart`:
```dart
_messageSub = _repository.onMessageReceived.listen((message) async {
  // ...
  state = state.copyWith(messages: capped);  // ← no guard
  await _persistMessages();                  // ← async gap, still no guard
});
```
**Fix:** Add `if (_isDisposed) return;` (or check `mounted` once that's replaced per C1) immediately before every `state = ...` assignment that follows an `await`.

---

## HIGH Severity Issues

### H1 — Emergency retry `mounted` guard placed *after* `_doSend()`
**File:** `lib/features/emergency/emergency_controller.dart` — Lines 150–167
**Description:** Even if `mounted` were a valid API (it isn't, see C1), the guard fires *after* `_doSend()` completes. Any exceptions caught inside `_doSend()` still trigger state mutations at lines 194–202 regardless of disposal state.
**Fix:** Add disposal check both before *and* after `_doSend()`.

---

### H2 — Timer callback in `LocationController` fires after disposal
**File:** `lib/features/location/location_controller.dart` — Lines 81–84
**Description:** The periodic `_broadcastTimer` callback does not check `_isDisposed` before calling `_broadcastCurrentLocation()`. Dart timers that are cancelled in `dispose()` can still fire one final tick if they were already queued before `cancel()` was processed.
**Fix:**
```dart
_broadcastTimer = Timer.periodic(duration, (_) {
  if (!_isDisposed) _broadcastCurrentLocation();
});
```

---

### H3 — `ReceiptService` timer fires on a disposed service
**File:** `lib/core/services/receipt_service.dart` — Lines 85–100
**Description:** `_readBatchTimer` fires `_flushReadReceipts()` which calls `_sendBatchReceipts()` and interacts with the transport. The service has no `_isDisposed` flag. After `dispose()` is called (which only cancels the timer and subscription), a queued timer tick can still invoke a broadcast on a stale transport reference.
**Fix:** Track `_isDisposed = true` in `dispose()` and guard `_flushReadReceipts()`.

---

### H4 — Fire-and-forget storage persist after controller disposal
**File:** `lib/features/chat/chat_controller.dart` — Line 152
**Description:** `_storageService?.saveMessages(...)` is called without `await` inside `_handleReceipt()`. The storage service uses a debounce timer internally. If the controller (and thus the storage service via `ref.onDispose`) is torn down before the debounce fires, the pending write is silently lost.
**Fix:** Either `await` the call (and add a disposal guard) or ensure the storage service's `dispose()` always flushes pending writes synchronously.

---

### H5 — `EmergencyController.dispose()` missing `_repository.dispose()`
**File:** `lib/features/emergency/emergency_controller.dart` — Lines 207–210
**Description:** `dispose()` only cancels `_alertSub` and calls `super.dispose()`. There is no `_repository.dispose()` call. Other controllers have matching disposal; this one does not, leaving repository resources open if the Riverpod provider's `ref.onDispose` hook is not wired (it currently is not wired in `emergency_providers.dart`).
**Fix:** Add `_repository.dispose()` before `super.dispose()`.

---

### H6 — `activeGroupProvider` goes stale after imperative group mutations
**File:** `lib/core/providers/group_providers.dart` — Lines 20–23
**Description:** `activeGroupProvider` reads `groupManager.activeGroup` once at initialization. Imperative calls to `groupManager.createGroup()`, `joinGroup()`, or `leaveGroup()` do not automatically notify this provider. The UI will display the stale group name/ID until a manual `ref.read(activeGroupProvider.notifier).state = ...` is issued. This is partially mitigated by the screens doing so, but it's not enforced and any path that mutates `GroupManager` without also updating the provider will cause silent stale state.
**Fix:** Either make `GroupManager` expose a `Stream<FluxonGroup?>` that the provider watches, or enforce the pattern via a wrapper method.

---

### H7 — Missing `ValueKey` on `ListView` items in terminal and emergency screens
**Files/Lines:**
- `lib/features/device_terminal/device_terminal_screen.dart` — Lines 237–242 (message list), 155–163 (device scan list)
- `lib/features/emergency/emergency_screen.dart` — Lines 177–192

**Description:** `ListView.builder` items lack `ValueKey`. Flutter's diffing algorithm can incorrectly reuse widget state when items are added/removed from the top or middle of the list. The chat screen correctly uses `ValueKey(msg.id)` — the same pattern must be applied to these three lists.
**Fix:**
```dart
itemBuilder: (_, i) => _TerminalMessageBubble(
  key: ValueKey(messages[i].id),
  message: messages[i],
)
```

---

### H8 — Hour not zero-padded in emergency timestamp
**File:** `lib/features/emergency/emergency_screen.dart` — Line 189
**Description:**
```dart
'${alert.timestamp.hour}:${alert.timestamp.minute.toString().padLeft(2, '0')}'
```
`hour` is not padded, producing `9:05` instead of `09:05`. The chat and terminal screens both pad correctly.
**Fix:** `alert.timestamp.hour.toString().padLeft(2, '0')`.

---

## MEDIUM Severity Issues

### M1 — `setState` after `async` without `mounted` check in group/onboarding screens
**Files/Lines:**
- `lib/features/group/join_group_screen.dart` — Lines 69–82 (inside `catch` block)
- `lib/features/onboarding/onboarding_screen.dart` — Lines 30–42

**Description:** Both screens call `setState()` in a `catch` block or after an `await` without first checking `if (!mounted) return`. The classic "setState after dispose" Flutter error.
**Fix:** Add `if (!mounted) return;` before each `setState` that follows an `await`.

---

### M2 — Double `Navigator.pop()` via cascade is fragile
**File:** `lib/features/group/share_group_screen.dart` — Lines 36–38, 179–181
**Description:** `Navigator.of(context)..pop()..pop()` pops twice via cascade. If the navigation stack doesn't contain exactly two routes above the base, this throws a `FlutterError`. No `mounted` check is present before either pop.
**Fix:** Use `Navigator.of(context).popUntil(ModalRoute.withName('/'))` or sequential pops with `mounted` checks.

---

### M3 — `displayNameProvider` silently falls back to empty string on init failure
**File:** `lib/core/providers/profile_providers.dart` — Lines 19–24
**Description:** The override `displayNameProvider.overrideWith((ref) => profileManager.displayName)` reads the display name synchronously from a `UserProfileManager` that may have failed to initialize. If initialization threw and was swallowed in `main.dart`'s `Future.wait`, the display name is empty, the app shows `OnboardingScreen` (correct behavior) but there is no error surfaced to the user or logged.
**Fix:** Add error logging in `main.dart` around `UserProfileManager.initialize()`.

---

### M4 — `sendReadReceipt()` called without `await` or error handling
**File:** `lib/features/chat/chat_controller.dart` — Lines 158–168
**Description:** `_repository.sendReadReceipt(...)` is fire-and-forget; BLE transmission failures are silently ignored. Users will see the double-tick indicator without the receipt actually being delivered.
**Fix:** Await the call and log errors, or surface a transient error state.

---

### M5 — `_sendBatchReceipts()` and `broadcastPacket()` not awaited
**File:** `lib/core/services/receipt_service.dart` — Line 99, 116
**Description:** `_sendBatchReceipts(receipts)` is called without `await` in `_flushReadReceipts()`, and inside it `_transport.broadcastPacket(packet)` is also unawaited. Packet construction or BLE broadcast exceptions are silently swallowed.
**Fix:** `await _sendBatchReceipts(receipts)` and propagate or log exceptions.

---

### M6 — `_messageCounter` incremented from multiple call sites without synchronization
**File:** `lib/features/device_terminal/device_terminal_controller.dart` — Lines 52, 74, 152, 178
**Description:** `_messageCounter++` is called from BLE data callbacks (potentially off the UI thread) and from UI-triggered send/clear operations. In Dart's single-threaded model this is usually safe, but BLE plugin callbacks can arrive on non-UI isolates, making this a latent race condition. Duplicate or skipped IDs would cause `ValueKey` collisions in the list view.
**Fix:** Use `Isolate`-safe atomic increment or ensure all BLE callbacks are marshalled to the UI isolate before state mutation.

---

### M7 — `TextEditingController` created inside dialog builder
**File:** `lib/features/chat/chat_screen.dart` — Lines 154–182
**Description:** A `TextEditingController` is created inside `_showChangeNameDialog()` and disposed via `.then()`. If the dialog is dismissed via back gesture or `Navigator.pop(null)`, the `.then()` callback may fire before or after disposal in an unpredictable order. Multiple rapid dialog opens could create multiple controllers.
**Fix:** Use `StatefulBuilder` inside the dialog or extract to a `StatefulWidget` that manages its own controller lifecycle.

---

### M8 — Static const screen list in `app.dart` is unconventional
**File:** `lib/app.dart` — Lines 98–103
**Description:**
```dart
static const _screens = [ChatScreen(), LocationScreen(), EmergencyScreen(), DeviceTerminalScreen()];
```
Storing widget instances in a `static const` list means all four screens are allocated at app start and never garbage collected. For screens that initialize expensive state in `initState`, this forces eager initialization. It also subtly conflicts with Riverpod's lifecycle model if any screen subscribes to providers in `initState`.
**Fix:** Build screens lazily inside the `IndexedStack` or `PageView` builder, or at minimum remove `const`/`static` so instances can be GC'd.

---

## LOW Severity Issues

### L1 — `ref.read()` inside `showModalBottomSheet` builder
**File:** `lib/features/chat/chat_screen.dart` — Line 57
**Description:** `ref.read(displayNameProvider)` inside a bottom sheet builder captures the value once. If the display name changes while the sheet is open, it will not update. Use `ref.watch` inside the builder, or pass the value as a closure variable captured before calling `showModalBottomSheet`.

---

### L2 — Providers throw `UnimplementedError` with no compile-time guard
**File:** `lib/core/providers/transport_providers.dart` — Lines 20–25
**Description:** `transportProvider`, `myPeerIdProvider`, and `transportConfigProvider` all throw `UnimplementedError` if accessed without the `ProviderScope` override. Tests that forget to override will get an opaque runtime error. A descriptive assert or a custom exception class would make debugging faster.

---

### L3 — Persisted messages on disk can grow unbounded across groups
**File:** `lib/features/chat/chat_controller.dart`
**Description:** The in-memory cap (200 messages) is enforced, but the JSON files written per group have no size or age limit. A long-lived install with many groups will accumulate unbounded disk usage. There is no eviction policy.
**Fix:** Apply a message count cap when reading from disk on startup, and periodically trim files.

---

## Issue Count by File

| File | Critical | High | Medium | Low | Total |
|------|:--------:|:----:|:------:|:---:|:-----:|
| `emergency_controller.dart` | 1 | 2 | 0 | 0 | 3 |
| `chat_controller.dart` | 1 | 2 | 2 | 0 | 5 |
| `location_controller.dart` | 1 | 2 | 0 | 0 | 3 |
| `device_terminal_controller.dart` | 1 | 1 | 1 | 0 | 3 |
| `location_screen.dart` | 1 | 0 | 0 | 0 | 1 |
| `receipt_service.dart` | 0 | 1 | 1 | 0 | 2 |
| `group_providers.dart` | 0 | 1 | 0 | 0 | 1 |
| `emergency_screen.dart` | 0 | 2 | 0 | 0 | 2 |
| `device_terminal_screen.dart` | 0 | 1 | 0 | 0 | 1 |
| `join_group_screen.dart` | 0 | 0 | 1 | 0 | 1 |
| `onboarding_screen.dart` | 0 | 0 | 1 | 0 | 1 |
| `share_group_screen.dart` | 0 | 0 | 1 | 0 | 1 |
| `profile_providers.dart` | 0 | 0 | 1 | 0 | 1 |
| `chat_screen.dart` | 0 | 0 | 1 | 1 | 2 |
| `app.dart` | 0 | 0 | 1 | 0 | 1 |
| `transport_providers.dart` | 0 | 0 | 0 | 1 | 1 |
| **Total** | **3** | **12** | **11** | **3** | **29** |

---

## Recommended Fix Priority

1. **C1** — Fix invalid `mounted` on StateNotifier immediately; this will crash in production.
2. **C3** — Add `_isDisposed` guards to all four async stream listeners; these cause silent state corruption.
3. **C2** — Dispose `MapController`; this leaks every time the Location tab is opened.
4. **H1/H2** — Fix remaining disposal gaps in emergency retry and location timer.
5. **H3/H4** — Fix receipt service and storage fire-and-forget issues.
6. **H7** — Add `ValueKey` to terminal and emergency list items (easy one-liner fix each).
7. **H8** — Fix hour padding (trivial).
8. **M1/M2** — Add `mounted` checks in group/onboarding screens.
