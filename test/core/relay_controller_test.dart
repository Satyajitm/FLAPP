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
  });
}
