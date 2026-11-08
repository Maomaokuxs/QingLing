import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 封面/歌词检测服务：native 查内嵌封面 + 同名 .lrc，结果按 path+size+mtime 缓存。
class MediaTagsService {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 返回 {'hasCover': bool, 'hasLyrics': bool}，失败返回 null
  static Future<Map<String, bool>?> checkTags(
      int id, String path) async {
    try {
      final r = await _ch
          .invokeMethod('mediaTags', {'id': id, 'path': path}).timeout(
              const Duration(seconds: 15));
      final m = Map<String, dynamic>.from(r as Map);
      return {
        'hasCover': m['hasCover'] == true,
        'hasLyrics': m['hasLyrics'] == true,
      };
    } catch (_) {
      return null;
    }
  }
}

/// 封面/歌词检测结果缓存：key=path，value={size, mtime, hasCover, hasLyrics}
class MediaTagsCache {
  static const _fileName = 'media_tags_cache.json';
  final Map<String, Map<String, dynamic>> _map;

  MediaTagsCache(this._map);

  static Future<MediaTagsCache> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (!await f.exists()) return MediaTagsCache({});
      final m =
          Map<String, dynamic>.from(json.decode(await f.readAsString()));
      return MediaTagsCache(
          m.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map))));
    } catch (_) {
      return MediaTagsCache({});
    }
  }

  /// 命中返回 {'hasCover':bool,'hasLyrics':bool}，未命中返回 null
  Map<String, bool>? get(String path, int size) {
    final e = _map[path];
    if (e == null) return null;
    if (e['size'] != size) return null;
    return {
      'hasCover': e['hasCover'] == true,
      'hasLyrics': e['hasLyrics'] == true,
    };
  }

  Future<void> put(String path, int size, bool hasCover, bool hasLyrics) async {
    _map[path] = {
      'size': size,
      'hasCover': hasCover,
      'hasLyrics': hasLyrics,
    };
    await _save();
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      await f.writeAsString(json.encode(_map));
    } catch (_) {}
  }
}
