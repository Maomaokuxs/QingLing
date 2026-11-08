import 'package:flutter/services.dart';

/// 音频技术元数据与频谱分析（native：song_dedup/scanner 通道）。
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

  /// 频谱分析：解码中间 15 秒做分窗 FFT。
  /// 返回 {sampleRate, rolloffHz, highFreqRatio, windows}，失败返回 null。
  /// rolloffHz = 99% 能量滚降频率；真无损一般 ≥20kHz，
  /// MP3 转制的"假 FLAC"通常在 16kHz 附近被一刀切。
  static Future<Map<String, dynamic>?> analyzeSpectrum(
      int id, String path) async {
    try {
      final r = await _ch
          .invokeMethod('analyzeSpectrum', {'id': id, 'path': path}).timeout(
              const Duration(seconds: 30));
      return Map<String, dynamic>.from(r as Map);
    } catch (_) {
      return null;
    }
  }

  /// 是否疑似假无损：标称无损（FLAC/WAV）但高频能量缺失。
  static bool isFakeLosslessSuspect(Map<String, dynamic> r) {
    final rolloff = (r['rolloffHz'] as num?)?.toDouble() ?? 0;
    return rolloff > 0 && rolloff < 17000;
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
