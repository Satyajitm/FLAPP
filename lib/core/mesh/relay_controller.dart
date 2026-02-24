import 'dart:math';
import '../protocol/message_types.dart';
import '../transport/transport_config.dart';

/// Encapsulates a single relay scheduling choice.
class RelayDecision {
  final bool shouldRelay;
  final int newTTL;
  final int delayMs;

  const RelayDecision({
    required this.shouldRelay,
    required this.newTTL,
    required this.delayMs,
  });
}

/// Centralizes flood control policy for relays.
///
/// Ported from Bitchat's RelayController.
class RelayController {
  static final _rng = Random.secure();

  /// Decide whether to relay a packet and with what parameters.
  ///
  /// - [ttl]: Current TTL on the packet.
  /// - [senderIsSelf]: True if we originated this packet.
  /// - [type]: The message type of the packet.
  /// - [isDirected]: True if the packet has a specific recipient (not broadcast).
  /// - [degree]: Number of currently connected peers (node degree).
  /// - [highDegreeThreshold]: Degree above which we consider the node "dense".
  static RelayDecision decide({
    required int ttl,
    required bool senderIsSelf,
    required MessageType type,
    bool isDirected = false,
    required int degree,
    int highDegreeThreshold = 6,
  }) {
    final ttlCap = min(ttl, TransportConfig.defaultConfig.maxTTL);

    // Suppress obvious non-relays
    if (ttlCap <= 1 || senderIsSelf) {
      return RelayDecision(shouldRelay: false, newTTL: ttlCap, delayMs: 0);
    }

    // For session-critical or directed traffic, be deterministic and reliable
    final isHandshake = type == MessageType.handshake;
    if (isHandshake || isDirected) {
      final newTTL = ttlCap - 1;
      // Tighter jitter for handshakes, slightly wider for directed traffic
      final delayRange = isHandshake ? (10, 35) : (20, 60);
      final delayMs = delayRange.$1 == delayRange.$2
          ? delayRange.$1
          : _rng.nextInt(delayRange.$2 - delayRange.$1) + delayRange.$1;
      return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs);
    }

    // Emergency alerts: always relay with minimal delay
    if (type == MessageType.emergencyAlert) {
      return RelayDecision(
        shouldRelay: true,
        newTTL: ttlCap - 1,
        delayMs: _rng.nextInt(20) + 5,
      );
    }

    // TTL clamping for broadcast
    final isAnnounce = type == MessageType.topologyAnnounce;
    final int ttlLimit;
    if (degree >= highDegreeThreshold) {
      ttlLimit = max(2, min(ttlCap, 5));
    } else {
      final preferred = isAnnounce ? 7 : 6;
      ttlLimit = max(2, min(ttlCap, preferred));
    }
    final newTTL = ttlLimit - 1;

    // Adaptive jitter by node degree
    final int delayMs;
    if (degree <= 2) {
      delayMs = _rng.nextInt(31) + 10; // 10..40
    } else if (degree <= 5) {
      delayMs = _rng.nextInt(91) + 60; // 60..150
    } else if (degree <= 9) {
      delayMs = _rng.nextInt(101) + 80; // 80..180
    } else {
      delayMs = _rng.nextInt(121) + 100; // 100..220
    }

    return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs);
  }
}
