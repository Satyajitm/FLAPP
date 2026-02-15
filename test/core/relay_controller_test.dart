import 'package:flutter_test/flutter_test.dart';
import 'package:fluxon_app/core/mesh/relay_controller.dart';
import 'package:fluxon_app/core/protocol/message_types.dart';

void main() {
  group('RelayController', () {
    test('does not relay when TTL <= 1', () {
      final decision = RelayController.decide(
        ttl: 1,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 3,
      );
      expect(decision.shouldRelay, isFalse);
    });

    test('does not relay own messages', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: true,
        type: MessageType.chat,
        degree: 3,
      );
      expect(decision.shouldRelay, isFalse);
    });

    test('always relays handshakes', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.handshake,
        degree: 3,
      );
      expect(decision.shouldRelay, isTrue);
      expect(decision.delayMs, lessThanOrEqualTo(35));
      expect(decision.delayMs, greaterThanOrEqualTo(10));
    });

    test('always relays emergency alerts', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.emergencyAlert,
        degree: 3,
      );
      expect(decision.shouldRelay, isTrue);
      expect(decision.delayMs, lessThan(30));
    });

    test('relays directed traffic with short delay', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.chat,
        isDirected: true,
        degree: 3,
      );
      expect(decision.shouldRelay, isTrue);
      expect(decision.delayMs, lessThanOrEqualTo(60));
    });

    test('decrements TTL on relay', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 3,
      );
      expect(decision.shouldRelay, isTrue);
      expect(decision.newTTL, lessThan(5));
    });

    test('sparse network has low jitter', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 1,
      );
      expect(decision.delayMs, lessThanOrEqualTo(40));
    });

    test('dense network has higher jitter', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 10,
      );
      expect(decision.delayMs, greaterThanOrEqualTo(100));
    });

    test('high degree clamps TTL lower', () {
      final decision = RelayController.decide(
        ttl: 7,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 8,
        highDegreeThreshold: 6,
      );
      expect(decision.newTTL, lessThanOrEqualTo(4)); // capped at 5 - 1
    });

    test('TTL=0 does not relay', () {
      final decision = RelayController.decide(
        ttl: 0,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 3,
      );
      expect(decision.shouldRelay, isFalse);
    });

    test('TTL above maxTTL is clamped and still relays', () {
      final decision = RelayController.decide(
        ttl: 10, // Above maxTTL (7)
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 3,
      );
      expect(decision.shouldRelay, isTrue);
      // newTTL should be based on clamped value, not original
      expect(decision.newTTL, lessThanOrEqualTo(6)); // max(2, min(7, 6)) - 1 = 5
    });

    test('emergency alert delay has correct bounds (5-24ms)', () {
      // Run multiple times to check bounds statistically
      for (var i = 0; i < 50; i++) {
        final decision = RelayController.decide(
          ttl: 5,
          senderIsSelf: false,
          type: MessageType.emergencyAlert,
          degree: 3,
        );
        expect(decision.delayMs, greaterThanOrEqualTo(5));
        expect(decision.delayMs, lessThanOrEqualTo(24));
      }
    });

    test('directed non-handshake delay bounds (20-59ms)', () {
      for (var i = 0; i < 50; i++) {
        final decision = RelayController.decide(
          ttl: 5,
          senderIsSelf: false,
          type: MessageType.chat,
          isDirected: true,
          degree: 3,
        );
        expect(decision.delayMs, greaterThanOrEqualTo(20));
        expect(decision.delayMs, lessThanOrEqualTo(59));
      }
    });

    test('degree=3 falls into mid-range jitter band (60-150ms)', () {
      for (var i = 0; i < 20; i++) {
        final decision = RelayController.decide(
          ttl: 5,
          senderIsSelf: false,
          type: MessageType.chat,
          degree: 3,
        );
        expect(decision.delayMs, greaterThanOrEqualTo(60));
        expect(decision.delayMs, lessThanOrEqualTo(150));
      }
    });

    test('degree=6 falls into upper-mid jitter band (80-180ms)', () {
      for (var i = 0; i < 20; i++) {
        final decision = RelayController.decide(
          ttl: 5,
          senderIsSelf: false,
          type: MessageType.chat,
          degree: 6,
        );
        expect(decision.delayMs, greaterThanOrEqualTo(80));
        expect(decision.delayMs, lessThanOrEqualTo(180));
      }
    });

    test('degree=10+ falls into highest jitter band (100-220ms)', () {
      for (var i = 0; i < 20; i++) {
        final decision = RelayController.decide(
          ttl: 5,
          senderIsSelf: false,
          type: MessageType.chat,
          degree: 12,
        );
        expect(decision.delayMs, greaterThanOrEqualTo(100));
        expect(decision.delayMs, lessThanOrEqualTo(220));
      }
    });

    test('topologyAnnounce has higher TTL preference in sparse network', () {
      final announce = RelayController.decide(
        ttl: 7,
        senderIsSelf: false,
        type: MessageType.topologyAnnounce,
        degree: 3,
      );
      final chat = RelayController.decide(
        ttl: 7,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 3,
      );

      // topologyAnnounce preferred=7, chat preferred=6
      // announce newTTL = min(7, 7) - 1 = 6
      // chat newTTL = min(7, 6) - 1 = 5
      expect(announce.newTTL, greaterThanOrEqualTo(chat.newTTL));
    });

    test('degree at exactly highDegreeThreshold triggers dense clamping', () {
      final decision = RelayController.decide(
        ttl: 7,
        senderIsSelf: false,
        type: MessageType.chat,
        degree: 6,
        highDegreeThreshold: 6,
      );
      // Dense path: ttlLimit = max(2, min(7, 5)) = 5, newTTL = 4
      expect(decision.newTTL, lessThanOrEqualTo(4));
    });

    test('handshake TTL is simply decremented', () {
      final decision = RelayController.decide(
        ttl: 5,
        senderIsSelf: false,
        type: MessageType.handshake,
        degree: 3,
      );
      expect(decision.newTTL, equals(4)); // ttlCap - 1
    });
  });
}
