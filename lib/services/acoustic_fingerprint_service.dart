import 'package:flutter/services.dart';

/// 音频指纹：基于声音内容的感知哈希（不是文件字节哈希）。
///
/// native 解码 3 段音频做分窗 FFT，提取 32 个对数频带的能量分布，
/// 每段 32 位、共 96 位，hex 编码（24 字符）。同一音频转不同格式/
/// 码率后频谱形状基本不变；不同歌曲的汉明距离接近随机（~48 位）。
class AcousticFingerprintService {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 计算音频指纹，失败返回 null。成功时为 24 位 hex（96 bit）。
  static Future<String?> fingerprint(int id, String path) async {
    try {
      final r = await _ch
          .invokeMethod('audioFingerprint', {'id': id, 'path': path})
          // 单文件超时：个别难解码的文件不许卡住整批扫描
          .timeout(const Duration(seconds: 25));
      final m = Map<String, dynamic>.from(r as Map);
      final fp = m['fingerprint'] as String?;
      return (fp != null && fp.length == 24) ? fp : null;
    } catch (_) {
      return null;
    }
  }

  /// 两指纹的汉明距离（不同 bit 数）。输入非法返回 -1。
  static int hammingDistance(String a, String b) {
    if (a.length != 24 || b.length != 24) return -1;
    try {
      var x = BigInt.parse(a, radix: 16) ^ BigInt.parse(b, radix: 16);
      var n = 0;
      while (x != BigInt.zero) {
        if ((x & BigInt.one) == BigInt.one) n++;
        x = x >> 1;
      }
      return n;
    } catch (_) {
      return -1;
    }
  }

  /// 分段判同阈值：3 段音频每段 32 位，各段汉明距离 <=3 才视为同一音频。
  ///
  /// 之前用 96 位 pooled <=10，允许某一段差 10 位（整段完全不同）
  /// 也判同，同风格的不同歌曲容易撞车误判。真机实测同音频转格式
  /// （FLAC/MP3 夜曲）距离为 0，3 足够宽裕。
  static const int segThreshold = 3;

  /// 稀疏阈值：两个指纹的并集置位 <12 位时（纯音/极简信号），
  /// 汉明距离天然偏小，改用严格阈值避免误判。
  static const int sparseThreshold = 2;
  static const int sparseUnionBits = 12;

  static bool isSameAudio(String a, String b) {
    final d = hammingDistance(a, b);
    if (d < 0) return false;
    if (d == 0) {
      // 全零指纹（静音/解码失败）不参与分组，避免失败文件抱团误判
      return _popCount(a) > 0;
    }
    // 稀疏信号（纯音/极简）：并集置位少，汉明距离天然偏小，用严格阈值
    if (_unionBits(a, b) < sparseUnionBits) return d <= sparseThreshold;
    // 常规：3 段各自判定，每段 32 位差异 <=3
    for (var i = 0; i < 3; i++) {
      if (_segHamming(a, b, i) > segThreshold) return false;
    }
    return true;
  }

  static int _popCount(String fp) {
    var x = BigInt.parse(fp, radix: 16);
    var n = 0;
    while (x != BigInt.zero) {
      if ((x & BigInt.one) == BigInt.one) n++;
      x = x >> 1;
    }
    return n;
  }

  static int _unionBits(String a, String b) {
    var x = BigInt.parse(a, radix: 16) | BigInt.parse(b, radix: 16);
    var n = 0;
    while (x != BigInt.zero) {
      if ((x & BigInt.one) == BigInt.one) n++;
      x = x >> 1;
    }
    return n;
  }

  /// 第 seg 段（每段 8 hex = 32 位）的汉明距离
  static int _segHamming(String a, String b, int seg) {
    final sa = BigInt.parse(a.substring(seg * 8, seg * 8 + 8), radix: 16);
    final sb = BigInt.parse(b.substring(seg * 8, seg * 8 + 8), radix: 16);
    var x = sa ^ sb;
    var n = 0;
    while (x != BigInt.zero) {
      if ((x & BigInt.one) == BigInt.one) n++;
      x = x >> 1;
    }
    return n;
  }
}
