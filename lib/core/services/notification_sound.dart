import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

/// Plays a short notification tone when a message is received.
///
/// Generates a small WAV file at runtime (no bundled assets needed)
/// and caches it in the temp directory for reuse.
class NotificationSoundService {
  final AudioPlayer _player = AudioPlayer();
  String? _cachedPath;

  /// Play the notification sound. Generates the tone file on first call.
  Future<void> play() async {
    try {
      final path = await _ensureToneFile();
      await _player.play(DeviceFileSource(path));
    } catch (_) {
      // Silently ignore — sound is non-critical.
    }
  }

  Future<String> _ensureToneFile() async {
    if (_cachedPath != null && File(_cachedPath!).existsSync()) {
      return _cachedPath!;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/fluxon_notify.wav');
    await file.writeAsBytes(_generateToneWav());
    _cachedPath = file.path;
    return _cachedPath!;
  }

  /// Generates a short two-tone notification WAV (200ms, 16-bit mono, 44100 Hz).
  Uint8List _generateToneWav() {
    const sampleRate = 44100;
    const durationMs = 200;
    const numSamples = sampleRate * durationMs ~/ 1000; // 8820
    const bitsPerSample = 16;
    const numChannels = 1;
    const byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    const blockAlign = numChannels * bitsPerSample ~/ 8;
    const dataSize = numSamples * blockAlign;

    final buffer = ByteData(44 + dataSize);

    // RIFF header
    _writeString(buffer, 0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    _writeString(buffer, 8, 'WAVE');

    // fmt chunk
    _writeString(buffer, 12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little); // chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, numChannels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    _writeString(buffer, 36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    // Two-tone sine wave: 880 Hz for first half, 1047 Hz for second half
    // with a quick fade-in / fade-out envelope so it doesn't click.
    const freq1 = 880.0; // A5
    const freq2 = 1047.0; // C6
    const amplitude = 12000; // ~37% of max — audible but not jarring

    for (var i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final freq = i < numSamples ~/ 2 ? freq1 : freq2;
      var sample = sin(2 * pi * freq * t) * amplitude;

      // Fade envelope (first/last 5ms)
      const fadeSamples = sampleRate * 5 ~/ 1000;
      if (i < fadeSamples) {
        sample *= i / fadeSamples;
      } else if (i > numSamples - fadeSamples) {
        sample *= (numSamples - i) / fadeSamples;
      }

      buffer.setInt16(44 + i * 2, sample.round(), Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  void _writeString(ByteData data, int offset, String str) {
    for (var i = 0; i < str.length; i++) {
      data.setUint8(offset + i, str.codeUnitAt(i));
    }
  }

  void dispose() {
    _player.dispose();
  }
}
