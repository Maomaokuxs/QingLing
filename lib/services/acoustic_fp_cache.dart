import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 音频指纹缓存：path -> {mtime, fp}。
/// 解码+FFT 开销大（每文件数秒），按 path+mtime 缓存避免重复计算。
class AcousticFpCache {
  static const _fileName = 'acoustic_fp_cache.json';
  static const _maxEntries = 20000;

  final Map<String, _Entry> _entries = {};
  bool _dirty = false;

  AcousticFpCache._();

  static Future<AcousticFpCache> load() async {
    final c = AcousticFpCache._();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is Map<String, dynamic>) {
          raw.forEach((k, v) {
            if (v is Map<String, dynamic>) {
              c._entries[k] = _Entry(
                v['mtime'] as int? ?? 0,
                v['fp'] as String? ?? '',
              );
            }
          });
        }
      }
    } catch (_) {
      // 缓存损坏就丢弃重建，不影响主流程
    }
    return c;
  }

  /// 命中返回指纹；文件被修改/删除/无记录时返回 null
  /// 命中返回指纹；mtime 对不上/无记录时返回 null。
  /// mtime 由调用方从 MediaStore DATE_MODIFIED 传入（秒），
  /// 不再 FileStat 走直接路径（scoped storage 下可能无权限导致缓存永不命中）。
  String? lookup(String path, int mtime) {
    final e = _entries[path];
    if (e == null || e.fp.isEmpty) return null;
    return mtime == e.mtime ? e.fp : null;
  }

  void store(String path, int mtime, String fp) {
    if (fp.isEmpty) return;
    _entries[path] = _Entry(mtime, fp);
    _dirty = true;
  }

  Future<void> save() async {
    if (!_dirty) return;
    try {
      var list = _entries.entries.toList();
      if (list.length > _maxEntries) {
        list = list.sublist(list.length - _maxEntries);
      }
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      await f.writeAsString(jsonEncode({
        for (final e in list) e.key: {'mtime': e.value.mtime, 'fp': e.value.fp},
      }));
      _dirty = false;
    } catch (_) {
      // ignore
    }
  }
}

class _Entry {
  final int mtime;
  final String fp;
  _Entry(this.mtime, this.fp);
}
