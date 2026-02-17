/// All tunable parameters for the transport and mesh layers.
///
/// Ported from Bitchat's TransportConfig with Fluxonlink additions.
class TransportConfig {
  /// BLE scan interval in milliseconds.
  final int scanIntervalMs;

  /// BLE advertising interval in milliseconds.
  final int advertisingIntervalMs;

  /// Maximum simultaneous BLE connections.
  final int maxConnections;

  /// Connection timeout in milliseconds.
  final int connectionTimeoutMs;

  /// Maximum packet TTL (hop count).
  final int maxTTL;

  /// Base relay delay in milliseconds (before jitter).
  final int baseRelayDelayMs;

  /// Maximum relay jitter in milliseconds.
  final int maxRelayJitterMs;

  /// Deduplication cache size (number of packet IDs).
  final int dedupCacheSize;

  /// Deduplication cache TTL in seconds.
  final int dedupTTLSeconds;

  /// Topology link freshness threshold in seconds.
  final int topologyFreshnessSeconds;

  /// Location broadcast interval in seconds.
  final int locationBroadcastIntervalSeconds;

  /// Emergency alert re-broadcast count.
  final int emergencyRebroadcastCount;

  /// Duration the BLE scan stays ON during idle duty-cycle mode (milliseconds).
  final int dutyCycleScanOnMs;

  /// Duration the BLE scan stays OFF (paused) during idle duty-cycle mode
  /// (milliseconds). After this pause, a new ON period begins.
  final int dutyCycleScanOffMs;

  /// Seconds of inactivity (no packets sent or received) after which the
  /// transport enters idle duty-cycle scan mode to conserve battery.
  final int idleThresholdSeconds;

  const TransportConfig({
    this.scanIntervalMs = 2000,
    this.advertisingIntervalMs = 1000,
    this.maxConnections = 7,
    this.connectionTimeoutMs = 10000,
    this.maxTTL = 7,
    this.baseRelayDelayMs = 50,
    this.maxRelayJitterMs = 100,
    this.dedupCacheSize = 1024,
    this.dedupTTLSeconds = 300,
    this.topologyFreshnessSeconds = 60,
    this.locationBroadcastIntervalSeconds = 10,
    this.emergencyRebroadcastCount = 3,
    this.dutyCycleScanOnMs = 5000,
    this.dutyCycleScanOffMs = 10000,
    this.idleThresholdSeconds = 30,
  });

  static const TransportConfig defaultConfig = TransportConfig();
}
