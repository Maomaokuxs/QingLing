import 'package:flutter/services.dart';

/// Chroma 声学指纹：3 段 × 12 维音高类别向量（native 计算，L2 归一化）。
/// 只用于同名组内的细分（区分同一录音 vs 不同版本），不做全库比对。
class ChromaFingerprintService {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 计算 chroma 指纹，失败返回 null。成功时为 36 个 double。
  static Future<List<double>?> getChroma(int id, String path) async {
    try {
      final r = await _ch
          .invokeMethod('chromaFingerprint', {'id': id, 'path': path}).timeout(
              const Duration(seconds: 45));
      final m = Map<String, dynamic>.from(r as Map);
      final list =
          (m['chroma'] as List).map((e) => (e as num).toDouble()).toList();
      if (list.length != 36) return null;
      return list;
    } catch (_) {
      return null;
    }
  }

  /// 两两 chroma 相似度：3 段余弦相似度的均值。向量已归一化，点积即余弦。
  /// 同一录音转格式后接近 1.0；不同录音明显更低。
  static double similarity(List<double> a, List<double> b) {
    assert(a.length == 36 && b.length == 36);
    var sum = 0.0;
    for (var s = 0; s < 3; s++) {
      var dot = 0.0;
      for (var i = 0; i < 12; i++) {
        dot += a[s * 12 + i] * b[s * 12 + i];
      }
      sum += dot;
    }
    return sum / 3;
  }
}
