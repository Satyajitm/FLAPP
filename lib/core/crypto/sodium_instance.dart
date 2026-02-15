import 'package:sodium_libs/sodium_libs_sumo.dart';

/// Global accessor for the initialized [SodiumSumo] instance.
///
/// [SodiumSumoInit.init()] returns a [Future<SodiumSumo>]. This holder stores
/// the result so that synchronous code can access it via [sodiumInstance].
/// Must be initialized once at app startup before any crypto operations.
///
/// SodiumSumo is used instead of Sodium because the Noise protocol requires
/// raw X25519 scalar multiplication (crypto_scalarmult), which is only
/// available in the sumo build.
late final SodiumSumo sodiumInstance;

/// Call once in main() after awaiting SodiumSumoInit.init().
Future<void> initSodium() async {
  sodiumInstance = await SodiumSumoInit.init();
}
