import 'package:flutter/services.dart';

/// 频谱截止分析：假无损检测。
///
/// 原生解码 3 段做 FFT，返回截止频率（90 分位）与采样率；这里按
/// 截止/奈奎斯特比值判定。判定保守——只认明确的假货，边界不判
/// （宁可漏过）：比值 <0.85 判假，0.85~0.90 为边界不判，>=0.90 视为真。
///
/// 为什么 0.85：44.1kHz 下 320k MP3 的截止约 20kHz（比值 0.907），
/// 256k 约 19.6kHz（0.889），192k 约 18.5kHz（0.839），128k 约
/// 16.5kHz（0.748）。0.85 这条线能抓住 192k 及以下的转码，
/// 256k/320k 的漏掉也无妨（本身已是高音质，错留的代价小）；
/// 而个别母带在 20kHz 附近做温和低通的真无损也不会被误判。
class SpectralAnalysisService {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 无损扩展名才做分析。m4a 可能是 ALAC 也可能是 AAC，暂不做。
  static const losslessExts = {'flac', 'wav', 'aiff', 'aif', 'ape'};

  static bool isLosslessExt(String ext) =>
      losslessExts.contains(ext.toLowerCase());

  /// 分析一个文件，失败返回 null。成功时为截止频率与采样率。
  static Future<SpectralResult?> analyze(int id, String path) async {
    try {
      final r = await _ch
          .invokeMethod('spectralCutoff', {'id': id, 'path': path}).timeout(
              const Duration(seconds: 45));
      final m = Map<String, dynamic>.from(r as Map);
      final cutoff = (m['cutoffHz'] as num).toDouble();
      final sampleRate = (m['sampleRate'] as num).toInt();
      if (cutoff <= 0 || sampleRate <= 0) return null;
      return SpectralResult(cutoffHz: cutoff, sampleRate: sampleRate);
    } catch (_) {
      return null;
    }
  }
}

class SpectralResult {
  final double cutoffHz;
  final int sampleRate;
  const SpectralResult({required this.cutoffHz, required this.sampleRate});

  double get nyquist => sampleRate / 2;
  double get ratio => cutoffHz / nyquist;

  /// 疑似假无损：截止明显低于奈奎斯特（比值 <0.85）。
  bool get isFakeLossless => ratio < 0.85;

  /// 按截止频率估算真实来源码率档位（MP3 特征截止）：
  /// 16.5k→128k，17.5k→160k，18.5k→192k，19.6k→256k，20.5k→320k。
  /// 超过 20.5k 仍判假的（如 48kHz 源），按 320k 计。
  int get estimatedTrueBitrateKbps {
    if (cutoffHz <= 16500) return 128;
    if (cutoffHz <= 17500) return 160;
    if (cutoffHz <= 18500) return 192;
    if (cutoffHz <= 19600) return 256;
    return 320;
  }
}
