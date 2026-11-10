import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';

/// 扫描历史：每次扫描完成后把结果写成纯文本报告，放到应用外部
/// 目录 `scan_history/` 下，供调试核验（adb 可直接读取，无需 root）。
///
/// 文件名：`scan_YYYY-MM-DD_HH-mm-ss.txt`，另写一份 `latest.txt`
/// 始终指向最近一次扫描；只保留最近 10 份历史报告。
class ScanHistoryService {
  static const _dirName = 'scan_history';
  static const _maxKept = 10;

  /// 写一份扫描报告。调用处在 home_screen 的 _scan() 末尾。
  /// [stageMs]：分阶段耗时（毫秒），key 见 home_screen 的 _scan()；
  /// [newOrChanged]：增量扫描的新增/变更文件数，全量扫描时为 -1；
  /// [includeShort]：本次扫描是否包含 30 秒以下短音频。
  /// [allSongs]：本次扫描认到的全部歌曲；提供时另写一份 scan_files.txt
  /// （路径清单，供调试核对扫描范围，如 MediaStore 总数对不上时找漏扫）。
  static Future<void> record({
    required List<DuplicateGroup> groups,
    required Map<String, Set<String>> selections,
    required int totalSongs,
    required String scopeKey,
    Map<String, int> stageMs = const {},
    int newOrChanged = -1,
    bool includeShort = false,
    List<SongFile>? allSongs,
  }) async {
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/$_dirName');
      if (!await dir.exists()) await dir.create(recursive: true);

      final now = DateTime.now();
      final stamp = _stamp(now);
      final buf = StringBuffer()
        ..writeln('清聆扫描记录')
        ..writeln('扫描时间：${_readable(now)}')
        ..writeln('扫描范围：$scopeKey')
        ..writeln('扫描模式：${newOrChanged < 0 ? '全量' : '增量（新增/变更 $newOrChanged 首）'}')
        ..writeln('短音频：${includeShort ? '包含（<30 秒）' : '不含（仅 ≥30 秒）'}')
        ..writeln('歌曲总数：$totalSongs')
        ..writeln('重复组数：${groups.length}');
      var deleteCount = 0;
      for (final g in groups) {
        deleteCount += selections[g.key]?.length ?? 0;
      }
      buf.writeln('自动勾选删除：$deleteCount 首');
      // 耗时统计（毫秒）
      final totalMs = stageMs['totalMs'] ?? 0;
      buf
        ..writeln()
        ..writeln('耗时统计（总计 ${_fmtMs(totalMs)}）：')
        ..writeln('  媒体库扫描：${_fmtMs(stageMs['mediaScanMs'] ?? 0)}')
        ..writeln('  缓存加载：${_fmtMs(stageMs['cacheLoadMs'] ?? 0)}')
        ..writeln('  Tier 1-3 分组：${_fmtMs(stageMs['tier123Ms'] ?? 0)}')
        ..writeln('  元数据版本细分：${_fmtMs(stageMs['metadataMs'] ?? 0)}')
        ..writeln(
            '  声学细分（chroma）：${_fmtMs(stageMs['chromaMs'] ?? 0)}')
        ..writeln(
            '  Tier 4 文件哈希：${_fmtMs(stageMs['fileHashMs'] ?? 0)}（候选 ${stageMs['tier4Candidates'] ?? 0} 首）')
        ..writeln(
            '  频谱分析（假无损）：${_fmtMs(stageMs['spectralMs'] ?? 0)}')
        ..writeln('  自动勾选：${_fmtMs(stageMs['autoSelectMs'] ?? 0)}')
        ..writeln('  缓存保存：${_fmtMs(stageMs['cacheSaveMs'] ?? 0)}');
      buf.writeln();

      for (var i = 0; i < groups.length; i++) {
        final g = groups[i];
        final selected = selections[g.key] ?? <String>{};
        buf
          ..writeln('[组 ${i + 1}] ${g.displayTitle}')
          ..writeln('  原因：${g.reason}')
          ..writeln('  不自动勾选：${g.noAutoSelect ? '是' : '否'}');
        for (final s in g.songs) {
          final mark = selected.contains(s.path) ? '删除' : '保留';
          final dur = (s.durationMs / 1000).toStringAsFixed(1);
          final size = (s.sizeBytes / 1024 / 1024).toStringAsFixed(2);
          // 频谱截止：已分析的无损文件都记，便于核对真假判定
          var spectralInfo = '';
          if (s.spectral != null) {
            final cutoff = (s.spectral!.cutoffHz / 1000).toStringAsFixed(1);
            spectralInfo = s.isFakeLossless
                ? '，疑似假无损（频谱截止 ${cutoff}kHz，约 ${s.spectral!.estimatedTrueBitrateKbps}kbps 来源）'
                : '，频谱截止 ${cutoff}kHz';
          }
          buf.writeln(
              '  $mark：${s.displayName}（${s.artist}，${s.bitrateKbps}kbps，${dur}s，${size}MB$spectralInfo）');
          buf.writeln('    路径：${s.path}');
        }
        buf.writeln();
      }

      final text = buf.toString();
      await File('${dir.path}/scan_$stamp.txt').writeAsString(text);
      await File('${dir.path}/latest.txt').writeAsString(text);
      // 扫描到的全部文件路径清单（调试用，adb 可直接读取）
      if (allSongs != null) {
        final paths = allSongs.map((s) => s.path).toList()..sort();
        await File('${dir.path}/scan_files.txt')
            .writeAsString(paths.join('\n'));
      }
      await _prune(dir);
    } catch (_) {
      // 历史记录失败不影响扫描主流程，静默忽略
    }
  }

  static String _stamp(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)}_${p(t.hour)}-${p(t.minute)}-${p(t.second)}';
  }

  static String _readable(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  /// 毫秒格式化：≥1000 显示秒（1 位小数），否则显示毫秒。
  static String _fmtMs(int ms) {
    if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${ms}ms';
  }

  static Future<void> _prune(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.txt'))
          .cast<File>()
          .toList();
      files.removeWhere((f) => f.path.endsWith('latest.txt'));
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(_maxKept)) {
        await f.delete();
      }
    } catch (_) {}
  }
}
