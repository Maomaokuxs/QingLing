import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import 'similarity_service.dart';

/// 扫描结果持久化：groups + 全部文件清单 + 用户勾选 + 扫描范围指纹。
///
/// 用于增量扫描：重扫时对比当前文件清单与缓存的 [allFiles]，
/// 识别新增/删除/变更的文件，只对新增/变更做分组，旧组直接复用。
/// 变更判定用 MediaStore 的 DATE_MODIFIED + 文件大小（[SongFile.dateModified]
/// 与 [SongFile.sizeBytes]），不用 FileStat——scoped storage 下
/// FileStat 走文件路径可能无权限。
///
/// 缓存有效性：保存时写 [SimilarityService.groupingVersion]，
/// 加载时版本对不上（分组逻辑改过）→ 缓存失效、走全量扫描。
/// 没有这层校验，一次错分组会靠增量扫描永远复用下去。
class ScanCache {
  static const _fileName = 'scan_cache.json';

  /// 保存：分组结果 + 本次扫描的全部文件清单。
  static Future<void> save({
    required List<DuplicateGroup> groups,
    required Map<String, Set<String>> selections,
    required String scopeKey,
    required int totalSongs,
    required List<SongFile> allSongs,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      await f.writeAsString(jsonEncode({
        'savedAt': DateTime.now().toIso8601String(),
        'scopeKey': scopeKey,
        // 分组逻辑版本：加载时对不上即失效（见类文档）
        'groupingVersion': SimilarityService.groupingVersion,
        'totalSongs': totalSongs,
        'groups': [for (final g in groups) g.toJson()],
        'selections': {
          for (final e in selections.entries) e.key: e.value.toList(),
        },
        // 全部文件清单：增量 diff 用。存完整 SongFile（不只是
        // path/mtime/size），这样原生扫描跳过未变文件时，Dart 层能
        // 直接用缓存里的 SongFile，不用再读一遍元数据。
        'allFiles': [for (final s in allSongs) s.toJson()],
      }));
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  /// 缓存的分组版本是否与当前逻辑一致（纯函数，便于测试）。
  /// 旧缓存无 groupingVersion 字段 → null != 当前版本 → false。
  static bool isGroupingVersionCurrent(Map<String, dynamic> raw) {
    return raw['groupingVersion'] == SimilarityService.groupingVersion;
  }

  /// 加载：scopeKey 不符 / 分组版本不符 / 解析失败 /
  /// 旧格式（allFiles 只有 path/mtime/size、无完整 SongFile）→ null，
  /// 走全量扫描。
  static Future<ScanCacheData?> load(String scopeKey) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      if (raw['scopeKey'] != scopeKey) return null;
      // 分组逻辑改过（或旧缓存无版本号）→ 缓存失效，全量重扫
      if (!isGroupingVersionCurrent(raw)) return null;
      final allFilesRaw = raw['allFiles'];
      if (allFilesRaw is! List) return null; // 旧格式，无文件清单
      final allFiles = <SongFile>[];
      for (final e in allFilesRaw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        // 旧格式只有 path/mtime/size，没有 title 等字段 → 整体失效
        if (m['title'] is! String || m['durationMs'] is! num) return null;
        try {
          allFiles.add(SongFile.fromJson(m));
        } catch (_) {
          return null;
        }
      }
      final groups = <DuplicateGroup>[];
      for (final gj in (raw['groups'] as List? ?? [])) {
        try {
          groups.add(DuplicateGroup.fromJson(
              Map<String, dynamic>.from(gj as Map)));
        } catch (_) {}
      }
      final selections = <String, Set<String>>{};
      final selRaw = raw['selections'];
      if (selRaw is Map<String, dynamic>) {
        selRaw.forEach((k, v) {
          if (v is List) selections[k] = v.map((e) => e.toString()).toSet();
        });
      }
      return ScanCacheData(
        groups: groups,
        selections: selections,
        totalSongs: (raw['totalSongs'] as int?) ?? 0,
        savedAt:
            DateTime.tryParse(raw['savedAt'] as String? ?? '') ?? DateTime.now(),
        allFiles: allFiles,
      );
    } catch (_) {
      return null;
    }
  }

  /// 增量 diff：当前扫描结果 vs 缓存文件清单。
  ///
  /// - 新增：path 不在缓存里；
  /// - 变更：path 在缓存里但 dateModified 或 sizeBytes 对不上（重编码/换标签）；
  /// - 其余：未变。
  /// 返回 (新增+变更, 未变)。删除的文件（缓存有、当前无）不需要返回，
  /// 调用方用 [refreshGroups] 剔除即可。
  static ({List<SongFile> changed, List<SongFile> unchanged}) splitNewVsOld(
    List<SongFile> current,
    List<SongFile> cached,
  ) {
    final cachedByPath = {for (final c in cached) c.path: c};
    final changed = <SongFile>[];
    final unchanged = <SongFile>[];
    for (final s in current) {
      final c = cachedByPath[s.path];
      if (c == null ||
          c.dateModified != s.dateModified ||
          c.sizeBytes != s.sizeBytes) {
        changed.add(s);
      } else {
        unchanged.add(s);
      }
    }
    return (changed: changed, unchanged: unchanged);
  }

  /// 刷新旧组：用本次扫描的新鲜 [SongFile] 替换组内对象；
  /// 剔除已删除（不在当前扫描里）与已变更（在 [changedPaths] 里，视为新文件）的歌；
  /// 组内 <2 首则整组丢弃。
  static List<DuplicateGroup> refreshGroups(
    List<DuplicateGroup> oldGroups,
    Map<String, SongFile> byPath,
    Set<String> changedPaths,
  ) {
    final result = <DuplicateGroup>[];
    for (final grp in oldGroups) {
      final fresh = <SongFile>[];
      for (final s in grp.songs) {
        if (changedPaths.contains(s.path)) continue;
        final f = byPath[s.path];
        if (f == null) continue;
        fresh.add(f);
      }
      if (fresh.length < 2) continue;
      result.add(DuplicateGroup(
        key: grp.key,
        songs: fresh,
        displayTitle: grp.displayTitle,
        reason: grp.reason,
        noAutoSelect: grp.noAutoSelect,
      ));
    }
    return result;
  }
}

class ScanCacheData {
  final List<DuplicateGroup> groups;
  final Map<String, Set<String>> selections;
  final int totalSongs;
  final DateTime savedAt;

  /// 全部文件清单（完整 SongFile）：增量 diff 与原生跳读共用。
  final List<SongFile> allFiles;
  ScanCacheData({
    required this.groups,
    required this.selections,
    required this.totalSongs,
    required this.savedAt,
    required this.allFiles,
  });
}
