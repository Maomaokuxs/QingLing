import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 频谱分析结果缓存：path -> {mtime, rolloffHz, highFreqRatio, sampleRate}。
/// 解码+FFT 开销不小（每个文件约 0.5~2s），按 path+mtime 缓存避免重复计算。
class SpectrumCache {
  static const _fileName = 'spectrum_cache.json';
  static const _maxEntries = 5000;

  final Map<String, _Entry> _entries = {};
  bool _dirty = false;

  SpectrumCache._();

  static Future<SpectrumCache> load() async {
    final c = SpectrumCache._();
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
                (v['rolloffHz'] as num?)?.toDouble() ?? 0,
                (v['highFreqRatio'] as num?)?.toDouble() ?? 0,
                (v['sampleRate'] as num?)?.toInt() ?? 0,
              );
            }
          });
        }
      }
    } catch (_) {
      // 缓存损坏就丢弃重建
    }
    return c;
  }

  /// 命中返回分析结果；mtime 对不上/无记录时返回 null。
  /// mtime 由调用方从 MediaStore DATE_MODIFIED 传入（秒），
  /// 不再 FileStat 走直接路径（scoped storage 下可能无权限导致缓存永不命中）。
  Map<String, dynamic>? lookup(String path, int mtime) {
    final e = _entries[path];
    if (e == null || e.rolloffHz <= 0) return null;
    if (mtime == e.mtime) {
      return {
        'rolloffHz': e.rolloffHz,
        'highFreqRatio': e.highFreqRatio,
        'sampleRate': e.sampleRate,
      };
    }
    return null;
  }

  void store(String path, int mtime, Map<String, dynamic> r) {
    final rolloff = (r['rolloffHz'] as num?)?.toDouble() ?? 0;
    if (rolloff <= 0) return;
    _entries[path] = _Entry(
      mtime,
      rolloff,
      (r['highFreqRatio'] as num?)?.toDouble() ?? 0,
      (r['sampleRate'] as num?)?.toInt() ?? 0,
    );
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
        for (final e in list)
          e.key: {
            'mtime': e.value.mtime,
            'rolloffHz': e.value.rolloffHz,
            'highFreqRatio': e.value.highFreqRatio,
            'sampleRate': e.value.sampleRate,
          },
      }));
      _dirty = false;
    } catch (_) {}
  }
}

class _Entry {
  final int mtime;
  final double rolloffHz;
  final double highFreqRatio;
  final int sampleRate;
  _Entry(this.mtime, this.rolloffHz, this.highFreqRatio, this.sampleRate);
}
