import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/services/foreground_service_manager.dart';

void main() {
  // ForegroundServiceManager guards all calls behind `Platform.isAndroid`.
  // In the test environment (desktop/host) that flag is false, so every
  // method is a no-op.  These tests verify:
  //  1. No exception is thrown on any non-Android platform.
  //  2. Repeated / out-of-order calls are safe.

  group('ForegroundServiceManager — non-Android platform guards', () {
    test('initialize() completes without error', () {
      expect(() => ForegroundServiceManager.initialize(), returnsNormally);
    });

    test('start() completes without error', () async {
      await expectLater(ForegroundServiceManager.start(), completes);
    });

    test('stop() completes without error', () async {
      await expectLater(ForegroundServiceManager.stop(), completes);
    });

    test('stop() before start() is safe', () async {
      await expectLater(ForegroundServiceManager.stop(), completes);
    });

    test('start() can be called multiple times without error', () async {
      await ForegroundServiceManager.start();
      await ForegroundServiceManager.start();
    });

    test('stop() can be called multiple times without error', () async {
      await ForegroundServiceManager.stop();
      await ForegroundServiceManager.stop();
    });

    test('full lifecycle: initialize → start → stop completes cleanly',
        () async {
      ForegroundServiceManager.initialize();
      await ForegroundServiceManager.start();
      await ForegroundServiceManager.stop();
    });

    test('initialize() is idempotent — calling twice does not throw', () {
      expect(() {
        ForegroundServiceManager.initialize();
        ForegroundServiceManager.initialize();
      }, returnsNormally);
    });
  });
}
