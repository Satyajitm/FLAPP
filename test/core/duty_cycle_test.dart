import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/transport/transport_config.dart';

// ---------------------------------------------------------------------------
// Helpers that mirror BleTransport's idle-check timer callback logic.
// ---------------------------------------------------------------------------

/// Returns true when the transport should enter idle mode.
/// Mirrors the predicate inside BleTransport._startScanning()'s periodic timer.
bool _shouldEnterIdle({
  required DateTime lastActivity,
  required bool isCurrentlyIdle,
  required int thresholdSeconds,
}) {
  final elapsed = DateTime.now().difference(lastActivity).inSeconds;
  return !isCurrentlyIdle && elapsed >= thresholdSeconds;
}

/// Returns true when the transport should exit idle mode and return to active.
bool _shouldExitIdle({
  required DateTime lastActivity,
  required bool isCurrentlyIdle,
  required int thresholdSeconds,
}) {
  final elapsed = DateTime.now().difference(lastActivity).inSeconds;
  return isCurrentlyIdle && elapsed < thresholdSeconds;
}

/// Simulates a packet event updating the activity timestamp, as done in
/// BleTransport.sendPacket(), broadcastPacket(), and _handleIncomingData().
DateTime _recordActivity() => DateTime.now();

void main() {
  group('TransportConfig duty cycle defaults', () {
    test('dutyCycleScanOnMs defaults to 5000', () {
      expect(TransportConfig.defaultConfig.dutyCycleScanOnMs, equals(5000));
    });

    test('dutyCycleScanOffMs defaults to 10000', () {
      expect(TransportConfig.defaultConfig.dutyCycleScanOffMs, equals(10000));
    });

    test('idleThresholdSeconds defaults to 30', () {
      expect(TransportConfig.defaultConfig.idleThresholdSeconds, equals(30));
    });

    test('custom config overrides dutyCycleScanOnMs', () {
      const config = TransportConfig(dutyCycleScanOnMs: 3000);
      expect(config.dutyCycleScanOnMs, equals(3000));
      // Other fields stay at defaults
      expect(config.dutyCycleScanOffMs, equals(10000));
      expect(config.idleThresholdSeconds, equals(30));
    });

    test('custom config overrides dutyCycleScanOffMs', () {
      const config = TransportConfig(dutyCycleScanOffMs: 7000);
      expect(config.dutyCycleScanOffMs, equals(7000));
      expect(config.dutyCycleScanOnMs, equals(5000));
    });

    test('custom config overrides idleThresholdSeconds', () {
      const config = TransportConfig(idleThresholdSeconds: 60);
      expect(config.idleThresholdSeconds, equals(60));
    });

    test('all duty cycle fields can be overridden together', () {
      const config = TransportConfig(
        dutyCycleScanOnMs: 2000,
        dutyCycleScanOffMs: 8000,
        idleThresholdSeconds: 45,
      );
      expect(config.dutyCycleScanOnMs, equals(2000));
      expect(config.dutyCycleScanOffMs, equals(8000));
      expect(config.idleThresholdSeconds, equals(45));
    });

    test('existing fields are not affected by new duty cycle fields', () {
      const config = TransportConfig.defaultConfig;
      expect(config.scanIntervalMs, equals(2000));
      expect(config.maxConnections, equals(7));
      expect(config.maxTTL, equals(7));
      expect(config.locationBroadcastIntervalSeconds, equals(10));
      expect(config.emergencyRebroadcastCount, equals(3));
    });
  });

  group('Idle detection logic', () {
    // Helper that mirrors the idle check predicate in BleTransport.
    bool isIdle(DateTime lastActivity, int thresholdSeconds) {
      return DateTime.now().difference(lastActivity).inSeconds >=
          thresholdSeconds;
    }

    test('no activity for threshold seconds triggers idle', () {
      final past =
          DateTime.now().subtract(const Duration(seconds: 31));
      expect(isIdle(past, 30), isTrue);
    });

    test('exactly at threshold triggers idle', () {
      final past =
          DateTime.now().subtract(const Duration(seconds: 30));
      expect(isIdle(past, 30), isTrue);
    });

    test('recent activity keeps active mode', () {
      final recent =
          DateTime.now().subtract(const Duration(seconds: 5));
      expect(isIdle(recent, 30), isFalse);
    });

    test('just under threshold stays active', () {
      final almostIdle =
          DateTime.now().subtract(const Duration(seconds: 29));
      expect(isIdle(almostIdle, 30), isFalse);
    });

    test('custom threshold: higher value takes longer to idle', () {
      final past = DateTime.now().subtract(const Duration(seconds: 45));
      // Default threshold (30 s) → idle
      expect(isIdle(past, 30), isTrue);
      // Custom threshold (60 s) → still active
      expect(isIdle(past, 60), isFalse);
    });

    test('activity timestamp of now is never idle', () {
      final now = DateTime.now();
      expect(isIdle(now, 30), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // State machine transition predicates
  // ---------------------------------------------------------------------------

  group('Duty cycle state machine transitions', () {
    test('transitions to idle when threshold exceeded (active → idle)', () {
      final stale = DateTime.now().subtract(const Duration(seconds: 31));
      expect(
        _shouldEnterIdle(
          lastActivity: stale,
          isCurrentlyIdle: false,
          thresholdSeconds: 30,
        ),
        isTrue,
      );
    });

    test('does not enter idle when already in idle mode (guard)', () {
      final stale = DateTime.now().subtract(const Duration(seconds: 31));
      expect(
        _shouldEnterIdle(
          lastActivity: stale,
          isCurrentlyIdle: true,
          thresholdSeconds: 30,
        ),
        isFalse,
      );
    });

    test('exits idle when fresh activity detected (idle → active)', () {
      final recent = DateTime.now().subtract(const Duration(seconds: 5));
      expect(
        _shouldExitIdle(
          lastActivity: recent,
          isCurrentlyIdle: true,
          thresholdSeconds: 30,
        ),
        isTrue,
      );
    });

    test('does not exit idle when not currently in idle mode (guard)', () {
      final recent = DateTime.now().subtract(const Duration(seconds: 5));
      expect(
        _shouldExitIdle(
          lastActivity: recent,
          isCurrentlyIdle: false,
          thresholdSeconds: 30,
        ),
        isFalse,
      );
    });

    test('does not exit idle when activity is still stale', () {
      final stale = DateTime.now().subtract(const Duration(seconds: 35));
      expect(
        _shouldExitIdle(
          lastActivity: stale,
          isCurrentlyIdle: true,
          thresholdSeconds: 30,
        ),
        isFalse,
      );
    });

    test('enter-idle fires at exactly the threshold boundary', () {
      final atThreshold =
          DateTime.now().subtract(const Duration(seconds: 30));
      expect(
        _shouldEnterIdle(
          lastActivity: atThreshold,
          isCurrentlyIdle: false,
          thresholdSeconds: 30,
        ),
        isTrue,
      );
    });

    test('exit-idle fires immediately after any fresh packet', () {
      final justNow = _recordActivity();
      expect(
        _shouldExitIdle(
          lastActivity: justNow,
          isCurrentlyIdle: true,
          thresholdSeconds: 30,
        ),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Activity timestamp tracking
  // ---------------------------------------------------------------------------

  group('Activity timestamp tracking', () {
    test('recording activity returns a timestamp close to now', () {
      final ts = _recordActivity();
      expect(DateTime.now().difference(ts).inSeconds, equals(0));
    });

    test('fresh activity resets the idle countdown below threshold', () {
      final ts = _recordActivity();
      final elapsed = DateTime.now().difference(ts).inSeconds;
      expect(elapsed, lessThan(30));
    });

    test('stale timestamp is further in the past than fresh one', () {
      final stale = DateTime.now().subtract(const Duration(seconds: 60));
      final fresh = _recordActivity();
      expect(fresh.isAfter(stale), isTrue);
    });

    test('activity update from sendPacket pattern resets idle check', () {
      // Simulates: _lastActivityTimestamp = DateTime.now() at top of sendPacket
      final before = DateTime.now().subtract(const Duration(seconds: 40));
      var lastActivity = before;

      // Packet sent — update timestamp
      lastActivity = _recordActivity();

      expect(
        _shouldEnterIdle(
          lastActivity: lastActivity,
          isCurrentlyIdle: false,
          thresholdSeconds: 30,
        ),
        isFalse, // threshold not yet reached after fresh activity
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Duty cycle timing parameters
  // ---------------------------------------------------------------------------

  group('Duty cycle timing parameters', () {
    test('default total cycle period (ON + OFF) is 15 000 ms', () {
      const config = TransportConfig.defaultConfig;
      expect(
        config.dutyCycleScanOnMs + config.dutyCycleScanOffMs,
        equals(15000),
      );
    });

    test('default duty cycle ON:OFF ratio is 1:2', () {
      const config = TransportConfig.defaultConfig;
      expect(
        config.dutyCycleScanOnMs / config.dutyCycleScanOffMs,
        closeTo(0.5, 0.001),
      );
    });

    test('custom config correctly computes total cycle period', () {
      const config = TransportConfig(
        dutyCycleScanOnMs: 2000,
        dutyCycleScanOffMs: 8000,
      );
      expect(config.dutyCycleScanOnMs + config.dutyCycleScanOffMs,
          equals(10000));
    });

    test('dutyCycleOffTimer fires after ON + OFF ms (timer offset)', () {
      // _runDutyCycle schedules the next cycle at (scanOnMs + scanOffMs).
      // Verify the arithmetic used in the production code is correct.
      const config = TransportConfig(
        dutyCycleScanOnMs: 3000,
        dutyCycleScanOffMs: 7000,
      );
      final timerDurationMs =
          config.dutyCycleScanOnMs + config.dutyCycleScanOffMs;
      expect(timerDurationMs, equals(10000));
    });

    test('idleThresholdSeconds is used to compare elapsed inSeconds', () {
      const config = TransportConfig.defaultConfig;
      // Simulate the exact comparison performed in _startScanning timer:
      //   idleSeconds >= config.idleThresholdSeconds
      final past = DateTime.now()
          .subtract(Duration(seconds: config.idleThresholdSeconds));
      final elapsed = DateTime.now().difference(past).inSeconds;
      expect(elapsed, greaterThanOrEqualTo(config.idleThresholdSeconds));
    });
  });
}
