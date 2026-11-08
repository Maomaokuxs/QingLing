import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 扫描缓存管理：指纹 / chroma 声学 / 封面歌词三项 JSON 缓存。
///
/// 所有缓存的 key 都绑定了 path + mtime（封面歌词还绑定 size），
/// 文件内容一变就自动失效重算，所以：
/// - 缓存不会影响扫描结果的可信度，只跳过"没变过的文件"的重复计算；
/// - 清除缓存只会让下次扫描变慢，结果完全不受影响。
class CacheService {
  static const _names = [
    'fingerprint_cache.json', // 文件指纹（Tier 4）
    'chroma_fp_cache.json', // 同名组声学细分指纹
    'media_tags_cache.json', // 封面/歌词检测
  ];

  static Future<int> sizeBytes() async {
    var total = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final n in _names) {
        final f = File('${dir.path}/$n');
        if (await f.exists()) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  /// 清除全部扫描缓存，返回释放的字节数。
  /// 不碰回收站、设置和忽略列表。
  static Future<int> clearAll() async {
    var freed = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final n in _names) {
        final f = File('${dir.path}/$n');
        if (await f.exists()) {
          freed += await f.length();
          await f.delete();
        }
      }
    } catch (_) {}
    return freed;
  }
}
