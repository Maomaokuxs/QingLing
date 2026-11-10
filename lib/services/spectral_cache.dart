import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'spectral_analysis_service.dart';

/// 频谱截止缓存：path -> {mtime, cutoffHz, sampleRate}。
/// mtime 取 MediaStore DATE_MODIFIED（秒），scoped storage 下直接 stat 不可靠。
class SpectralCache {
  static const _fileName = 'spectral_cache.json';
  static const _version = 1;

  final Map<String, _Entry> _map;

  SpectralCache._(this._map);

  static Future<SpectralCache> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (!await f.exists()) return SpectralCache._({});
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['version'] != _version) return SpectralCache._({});
      final entries = j['entries'] as Map<String, dynamic>? ?? {};
      final map = <String, _Entry>{};
      for (final e in entries.entries) {
        try {
          final m = Map<String, dynamic>.from(e.value as Map);
          map[e.key] = _Entry(
            mtime: (m['mtime'] as num).toInt(),
            cutoffHz: (m['cutoffHz'] as num).toDouble(),
            sampleRate: (m['sampleRate'] as num).toInt(),
          );
        } catch (_) {}
      }
      return SpectralCache._(map);
    } catch (_) {
      return SpectralCache._({});
    }
  }

  /// 命中返回频谱结果，否则 null。
  SpectralResult? lookup(String path, int mtime) {
    final e = _map[path];
    if (e == null || e.mtime != mtime) return null;
    return SpectralResult(cutoffHz: e.cutoffHz, sampleRate: e.sampleRate);
  }

  void store(String path, int mtime, SpectralResult r) {
    _map[path] = _Entry(
      mtime: mtime,
      cutoffHz: r.cutoffHz,
      sampleRate: r.sampleRate,
    );
  }

  Future<void> save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      final entries = <String, dynamic>{};
      for (final e in _map.entries) {
        entries[e.key] = {
          'mtime': e.value.mtime,
          'cutoffHz': e.value.cutoffHz,
          'sampleRate': e.value.sampleRate,
        };
      }
      await f.writeAsString(jsonEncode({'version': _version, 'entries': entries}));
    } catch (_) {}
  }
}

class _Entry {
  final int mtime;
  final double cutoffHz;
  final int sampleRate;
  _Entry({required this.mtime, required this.cutoffHz, required this.sampleRate});
}
