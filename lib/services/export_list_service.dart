import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';

/// 一条导出的清单：导出当时重复组里的全部歌曲快照，
/// 或删除前自动保存的被删歌曲快照（[source] 为 'delete'）。
///
/// 用途是事后找回：删掉的歌进了回收站，还能从清单里按原路径恢复；
/// 回收站已清空的，提示无法恢复。只记录歌曲信息，不复制音频文件。
class ExportList {
  final String id;
  final DateTime savedAt;
  final List<SongFile> songs;

  /// 来源：'manual' 手动导出，'delete' 删除前自动保存的删除备份。
  final String source;

  ExportList({
    required this.id,
    required this.savedAt,
    required this.songs,
    this.source = 'manual',
  });

  int get totalSize => songs.fold(0, (p, e) => p + e.sizeBytes);

  Map<String, dynamic> toJson() => {
    'id': id,
    'savedAt': savedAt.toIso8601String(),
    'songs': songs.map((s) => s.toJson()).toList(),
    'source': source,
  };

  factory ExportList.fromJson(Map<String, dynamic> j) => ExportList(
    id: j['id'] as String? ?? '',
    savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
    songs: (j['songs'] as List? ?? [])
        .map((e) {
          try {
            return SongFile.fromJson(Map<String, dynamic>.from(e as Map));
          } catch (_) {
            return null;
          }
        })
        .whereType<SongFile>()
        .toList(),
    source: j['source'] as String? ?? 'manual',
  );
}

/// 清单列表服务：导出记录的保存 / 读取 / 删除。
///
/// 存在应用文档目录 export_lists.json，最新在前。只存歌曲信息
/// （路径、标题、歌手、大小、码率），不复制音频文件。
class ExportListService {
  static const _fileName = 'export_lists.json';

  /// 单元测试覆盖存储目录的钩子；生产代码保持 null 走正常路径。
  static Future<Directory> Function()? testDir;

  static Future<File> _file() async {
    final dir = testDir != null
        ? await testDir!()
        : await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// 保存一条清单：取当前重复组里的全部歌曲。返回建好的记录。
  static Future<ExportList> save(List<DuplicateGroup> groups) async {
    return saveSongs(groups.expand((g) => g.songs).toList());
  }

  /// 按歌曲列表保存一条清单。删除流程用它存「删除备份」
  ///（只含被删的歌，[source] 为 'delete'），手动导出走 [save]。
  static Future<ExportList> saveSongs(
    List<SongFile> songs, {
    String source = 'manual',
  }) async {
    final list = ExportList(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      savedAt: DateTime.now(),
      songs: songs,
      source: source,
    );
    final all = await loadAll();
    all.insert(0, list);
    await _write(all);
    return list;
  }

  /// 导出重复清单：文本格式
  static String buildText(List<DuplicateGroup> groups) {
    final buf = StringBuffer();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    buf.writeln('清聆 重复清单');
    buf.writeln(
      '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}',
    );
    buf.writeln('共 ${groups.length} 组重复');
    buf.writeln('---');
    for (final g in groups) {
      buf.writeln('[${g.reason}] ${g.songs.length} 个版本');
      for (final f in g.songs) {
        buf.writeln(
          '  ${f.displayName} | ${f.formattedBitrate} | ${f.formattedSize}',
        );
        buf.writeln('  ${f.path}');
      }
      buf.writeln('');
    }
    return buf.toString();
  }

  /// 导出重复清单：M3U 播放列表格式
  static String buildM3u(List<DuplicateGroup> groups) {
    final buf = StringBuffer();
    buf.writeln('#EXTM3U');
    for (final g in groups) {
      for (final f in g.songs) {
        final secs = (f.durationMs / 1000).round();
        buf.writeln('#EXTINF:$secs,${f.artist} - ${f.title}');
        buf.writeln(f.path);
      }
    }
    return buf.toString();
  }

  /// 全部清单，最新在前。文件不存在或解析失败返回空列表。
  static Future<List<ExportList>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return [];
      final lists = raw
          .map((e) {
            try {
              return ExportList.fromJson(Map<String, dynamic>.from(e as Map));
            } catch (_) {
              return null;
            }
          })
          .whereType<ExportList>()
          .toList();
      lists.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return lists;
    } catch (_) {
      return [];
    }
  }

  /// 删除一条清单。
  static Future<void> delete(String id) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == id);
    await _write(all);
  }

  static Future<void> _write(List<ExportList> lists) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(lists.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }
}
