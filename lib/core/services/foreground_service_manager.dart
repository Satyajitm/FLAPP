import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the foreground task handler.
///
/// Must be a top-level function annotated with @pragma('vm:entry-point')
/// to prevent tree-shaking. Flutter calls this from the native service
/// context to set up the Dart task handler.
@pragma('vm:entry-point')
void fluxonForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_FluxonTaskHandler());
}

/// Minimal task handler — the foreground service exists only to keep
/// the Flutter engine alive for BLE relay. All BLE logic runs on the
/// main isolate; no periodic work is needed from the service itself.
class _FluxonTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Manages the Android foreground service lifecycle for BLE mesh relay.
///
/// iOS does not need a foreground service — background BLE is declared
/// in Info.plist via UIBackgroundModes: [bluetooth-central, bluetooth-peripheral].
///
/// All methods are no-ops on non-Android platforms.
class ForegroundServiceManager {
  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Configure the Android foreground service notification and task options.
  ///
  /// Call once after [WidgetsFlutterBinding.ensureInitialized] and before
  /// [runApp]. Safe to call on all platforms (no-op on iOS/desktop).
  static void initialize() {
    if (!_isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'fluxon_mesh_channel',
        channelName: 'Fluxon Mesh Service',
        channelDescription:
            'Keeps the BLE mesh relay running in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false, // iOS uses UIBackgroundModes instead
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic callbacks needed — BLE runs on the main isolate.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true, // Keep CPU alive for packet relay
        allowWifiLock: false,
      ),
    );
  }

  /// Start the foreground service and show the persistent notification.
  ///
  /// Call after BLE transport has started successfully. No-op on iOS/desktop.
  static Future<void> start() async {
    if (!_isAndroid) return;
    // L4: Wrap in try/catch — foreground service errors are non-fatal.
    try {
      await FlutterForegroundTask.startService(
        serviceId: 1001, // Fluxon mesh foreground service ID
        notificationTitle: 'Fluxon Mesh Active',
        notificationText: 'Relaying messages for your group',
        callback: fluxonForegroundTaskCallback,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[ForegroundServiceManager] start() failed: $e');
    }
  }

  /// Stop the foreground service and dismiss the notification.
  ///
  /// Call when BLE stops or the app is being destroyed. No-op on iOS/desktop.
  static Future<void> stop() async {
    if (!_isAndroid) return;
    // L4: Wrap in try/catch — foreground service errors are non-fatal.
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      // ignore: avoid_print
      print('[ForegroundServiceManager] stop() failed: $e');
    }
  }
}
