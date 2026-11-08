import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';

/// 扫描结果持久化：groups + 用户勾选 + 扫描范围指纹。
///
/// 加载时按 path+mtime+size 逐文件校验：任一对不上就丢弃该文件；
/// 组内有效文件 <2 则整组丢弃；扫描范围变化则整个缓存失效。
class ScanCache {
  static const _fileName = 'scan_cache.json';

  static Future<void> save({
    required List<DuplicateGroup> groups,
    required Map<String, Set<String>> selections,
    required String scopeKey,
    required int totalSongs,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      int mtimeOf(String path) {
        try {
          return FileStat.statSync(path).modified.millisecondsSinceEpoch;
        } catch (_) {
          return 0;
        }
      }

      await f.writeAsString(jsonEncode({
        'savedAt': DateTime.now().toIso8601String(),
        'scopeKey': scopeKey,
        'totalSongs': totalSongs,
        'groups': [
          for (final g in groups)
            {
              'key': g.key,
              'displayTitle': g.displayTitle,
              'reason': g.reason,
              'songs': [
                for (final s in g.songs)
                  {
                    ..._songToJson(s),
                    'mtime': mtimeOf(s.path),
                  },
              ],
            },
        ],
        'selections': {
          for (final e in selections.entries) e.key: e.value.toList(),
        },
      }));
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  static Future<ScanCacheData?> load(String scopeKey) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      if (raw['scopeKey'] != scopeKey) return null;
      final groups = <DuplicateGroup>[];
      final selections = <String, Set<String>>{};
      for (final gj in (raw['groups'] as List? ?? [])) {
        final gm = Map<String, dynamic>.from(gj as Map);
        final songs = <SongFile>[];
        for (final sj in (gm['songs'] as List? ?? [])) {
          final sm = Map<String, dynamic>.from(sj as Map);
          final s = _songFromJson(sm);
          if (s == null) continue;
          // 校验：文件存在且 mtime/size 未变
          try {
            final st = FileStat.statSync(s.path);
            if (st.modified.millisecondsSinceEpoch !=
                (sm['mtime'] as int? ?? -1)) {
              continue;
            }
            if (st.size != s.sizeBytes) continue;
          } catch (_) {
            continue;
          }
          songs.add(s);
        }
        if (songs.length < 2) continue;
        groups.add(DuplicateGroup(
          key: gm['key'] as String? ?? '',
          songs: songs,
          displayTitle: gm['displayTitle'] as String? ?? '',
          reason: gm['reason'] as String? ?? '',
        ));
      }
      if (groups.isEmpty) return null;
      final selRaw = raw['selections'];
      if (selRaw is Map<String, dynamic>) {
        selRaw.forEach((k, v) {
          if (v is List) selections[k] = v.map((e) => e.toString()).toSet();
        });
      }
      // 勾选中已不存在的路径清掉
      final validPaths =
          groups.expand((g) => g.songs.map((s) => s.path)).toSet();
      for (final k in selections.keys.toList()) {
        selections[k] =
            selections[k]!.where((p) => validPaths.contains(p)).toSet();
      }
      return ScanCacheData(
        groups: groups,
        selections: selections,
        totalSongs: (raw['totalSongs'] as int?) ?? 0,
        savedAt:
            DateTime.tryParse(raw['savedAt'] as String? ?? '') ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _songToJson(SongFile s) => {
        'id': s.id,
        'path': s.path,
        'displayName': s.displayName,
        'title': s.title,
        'artist': s.artist,
        'album': s.album,
        'durationMs': s.durationMs,
        'sizeBytes': s.sizeBytes,
        'extension': s.extension,
        'realBitrateKbps': s.realBitrateKbps,
        'fingerprint': s.fingerprint,
      };

  static SongFile? _songFromJson(Map<String, dynamic> j) {
    try {
      final path = j['path'] as String? ?? '';
      if (path.isEmpty) return null;
      return SongFile(
        id: (j['id'] as num?)?.toInt() ?? 0,
        path: path,
        displayName: j['displayName'] as String? ?? '',
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        extension: j['extension'] as String? ?? '',
        realBitrateKbps: (j['realBitrateKbps'] as num?)?.toInt() ?? 0,
        fingerprint: j['fingerprint'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

class ScanCacheData {
  final List<DuplicateGroup> groups;
  final Map<String, Set<String>> selections;
  final int totalSongs;
  final DateTime savedAt;
  ScanCacheData({
    required this.groups,
    required this.selections,
    required this.totalSongs,
    required this.savedAt,
  });
}
