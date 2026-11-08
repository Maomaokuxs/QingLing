import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Chroma 指纹缓存：path -> {mtime, chroma[36]}。
/// mtime 取 MediaStore DATE_MODIFIED（秒），scoped storage 下直接 stat 不可靠。
class ChromaFpCache {
  static const _fileName = 'chroma_fp_cache.json';
  static const _version = 1;

  final Map<String, _Entry> _map;

  ChromaFpCache._(this._map);

  static Future<ChromaFpCache> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (!await f.exists()) return ChromaFpCache._({});
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['version'] != _version) return ChromaFpCache._({});
      final entries = j['entries'] as Map<String, dynamic>? ?? {};
      final map = <String, _Entry>{};
      for (final e in entries.entries) {
        try {
          final m = Map<String, dynamic>.from(e.value as Map);
          final chroma = (m['chroma'] as List)
              .map((v) => (v as num).toDouble())
              .toList();
          if (chroma.length != 36) continue;
          map[e.key] = _Entry(
            mtime: (m['mtime'] as num).toInt(),
            chroma: chroma,
          );
        } catch (_) {}
      }
      return ChromaFpCache._(map);
    } catch (_) {
      return ChromaFpCache._({});
    }
  }

  /// 命中返回 36 个 double（3 段 × 12 维），否则 null。
  List<double>? lookup(String path, int mtime) {
    final e = _map[path];
    if (e == null || e.mtime != mtime) return null;
    return e.chroma;
  }

  void store(String path, int mtime, List<double> chroma) {
    if (chroma.length != 36) return;
    _map[path] = _Entry(mtime: mtime, chroma: chroma);
  }

  Future<void> save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      final entries = <String, dynamic>{};
      for (final e in _map.entries) {
        entries[e.key] = {'mtime': e.value.mtime, 'chroma': e.value.chroma};
      }
      await f.writeAsString(jsonEncode({'version': _version, 'entries': entries}));
    } catch (_) {}
  }
}

class _Entry {
  final int mtime;
  final List<double> chroma;
  _Entry({required this.mtime, required this.chroma});
}
