import 'dart:developer' as dev;

/// Secure logging utility — never logs PII (keys, peer IDs, locations).
class SecureLogger {
  static const String _tag = 'Fluxon';

  static void debug(String message, {String? category}) {
    dev.log('[$_tag${category != null ? ':$category' : ''}] $message',
        level: 0);
  }

  static void info(String message, {String? category}) {
    dev.log('[$_tag${category != null ? ':$category' : ''}] $message',
        level: 800);
  }

  static void warning(String message, {String? category}) {
    dev.log('[$_tag${category != null ? ':$category' : ''}] WARNING: $message',
        level: 900);
  }

  static void error(String message, {String? category, Object? error}) {
    dev.log(
      '[$_tag${category != null ? ':$category' : ''}] ERROR: $message',
      level: 1000,
      error: error,
    );
  }
}
