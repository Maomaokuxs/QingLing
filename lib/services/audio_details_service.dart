import 'package:flutter/services.dart';

/// 音频技术元数据（native：song_dedup/scanner 通道）。
class AudioDetailsService {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 采样率/声道。MediaExtractor 直接读封装头，不解码，很快。
  static Future<({int sampleRate, int channels})> getDetails(
    int id,
    String path,
  ) async {
    try {
      final r = await _ch.invokeMethod('audioDetails', {'id': id, 'path': path});
      final m = Map<String, dynamic>.from(r as Map);
      return (
        sampleRate: (m['sampleRate'] as int?) ?? 0,
        channels: (m['channels'] as int?) ?? 0,
      );
    } catch (_) {
      return (sampleRate: 0, channels: 0);
    }
  }

  static String formatSampleRate(int hz) {
    if (hz <= 0) return '未知';
    if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(1)}kHz';
    return '${hz}Hz';
  }

  static String formatChannels(int ch) {
    return switch (ch) {
      1 => '单声道',
      2 => '立体声',
      > 2 => '$ch 声道',
      _ => '未知',
    };
  }
}
