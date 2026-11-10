import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import '../services/media_tags_service.dart';
import '../services/audio_scanner.dart';
import '../services/delete_service.dart';
import '../services/export_list_service.dart';
import '../services/ignore_service.dart';
import '../services/quality_service.dart';
import '../services/scan_cache.dart';
import '../services/scan_history_service.dart';
import '../services/share_service.dart';
import '../services/similarity_service.dart';
import '../services/trash_service.dart';
import '../services/update_service.dart';
import '../widgets/group_card.dart';
import '../widgets/minimal_ui.dart';
import '../widgets/song_details_sheet.dart';
import '../widgets/update_prompt.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final scanner = AudioScanner();
  bool scanning = false;
  String status = '准备就绪';
  double scanProgress = 0;
  String scanPhase = '';
  List<DuplicateGroup> groups = [];
  List<SongFile> allSongs = [];
  final Map<String, Set<String>> selections = {};
  int totalSongs = 0;
  String searchQuery = '';
  String sortBy = 'count'; // count | size | free
  String reasonFilter = '全部'; // 全部 | 标题一致 | 不同版本
  bool multiSelectMode = false; // 长按进入的多选模式

  // 试听
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<double> _playProgress = ValueNotifier(0);
  // 调试通道：自动化测试用广播触发扫描，不影响正常使用
  static const _debugChannel = MethodChannel('song_dedup/debug');
  String? _playingPath;
  Timer? _previewTimer;
  final Map<String, bool> hasCoverMap = {};
  final Map<String, bool> hasLyricsMap = {};

  @override
  void initState() {
    super.initState();
    _maybeAutoScan();
    _maybeCheckUpdateOnStartup();
    _player.onPlayerComplete.listen((_) {
      _playProgress.value = 0;
      if (mounted) setState(() => _playingPath = null);
      _previewTimer?.cancel();
    });
    _player.onPositionChanged.listen((pos) {
      var p = pos.inMilliseconds / 10000;
      if (p > 1) p = 1;
      _playProgress.value = p;
    });
    _debugChannel.setMethodCallHandler((call) async {
      if (call.method == 'startScan' && !scanning && mounted) {
        await _scan();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _playProgress.dispose();
    _previewTimer?.cancel();
    super.dispose();
  }

  /// 从头播放（10 秒自动停），供试听/对比试听复用。
  Future<void> _playFromStart(SongFile s) async {
    await _player.stop();
    _previewTimer?.cancel();
    await _player.play(DeviceFileSource(s.path));
    _playProgress.value = 0;
    if (mounted) setState(() => _playingPath = s.path);
    // 10s 自动停止
    _previewTimer = Timer(const Duration(seconds: 10), () async {
      await _player.stop();
      _playProgress.value = 0;
      if (mounted) setState(() => _playingPath = null);
    });
  }

  Future<void> _stopPreview() async {
    _previewTimer?.cancel();
    await _player.stop();
    _playProgress.value = 0;
    if (mounted) setState(() => _playingPath = null);
  }

  Future<void> _togglePreview(SongFile s) async {
    try {
      if (_playingPath == s.path) {
        await _stopPreview();
      } else {
        await _playFromStart(s);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法试听: $e')));
    }
  }

  /// 对比试听专用：每次都从头播放（方便 AB 对比同一乐段），不做播放/停止切换。
  Future<void> _comparePlay(SongFile s) async {
    try {
      await _playFromStart(s);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法试听: $e')));
    }
  }

  /// AB 对比试听：从组内挑 A、B 两个版本，一键来回切换试听，决定保留哪个。
  Future<void> _showCompareSheet(DuplicateGroup g) async {
    final playingBefore = _playingPath;
    SongFile? pickA;
    SongFile? pickB;

    Widget abChip(String label, Color color) {
      return Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      );
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setState) {
          void assign(SongFile s) {
            setState(() {
              if (pickA?.path == s.path) {
                pickA = null;
              } else if (pickB?.path == s.path) {
                pickB = null;
              } else if (pickA == null) {
                pickA = s;
              } else {
                pickB = s;
              }
            });
          }

          Widget playButton(String tag, SongFile? pick, Color color) {
            return Expanded(
              child: FilledButton.icon(
                onPressed: pick == null ? null : () => _comparePlay(pick),
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text(
                  pick == null ? '未选$tag' : '$tag · ${pick.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                style: FilledButton.styleFrom(backgroundColor: color),
              ),
            );
          }

          final scheme = Theme.of(ctx2).colorScheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AB 对比试听',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    g.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final s in g.songs)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              s.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              '${s.extension.toUpperCase()} · ${s.formattedBitrate} · ${s.formattedSize}',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (pickA?.path == s.path)
                                  abChip('A', scheme.primary),
                                if (pickB?.path == s.path)
                                  abChip('B', Colors.orange.shade800),
                              ],
                            ),
                            selected:
                                pickA?.path == s.path || pickB?.path == s.path,
                            selectedTileColor: scheme.primary.withValues(
                              alpha: 0.08,
                            ),
                            onTap: () => assign(s),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      playButton('A', pickA, scheme.primary),
                      const SizedBox(width: 8),
                      playButton('B', pickB, Colors.orange.shade800),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '点歌曲设为 A / B（再点取消），选好后点下方按钮来回试听，每次都从头播放',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    // sheet 里开了新的试听才停掉；之前在播的不打断
    if (_playingPath != playingBefore) await _stopPreview();
  }

  /// 启动时：若开启自动扫描且距离上次扫描超过设定天数，则自动扫描
  /// 启动时检查更新（开关默认开）：首帧后静默查一次，有新版才弹提示，
  /// 已是最新 / 无 release / 检查失败都不打扰。
  void _maybeCheckUpdateOnStartup() {
    if (!updateCheckOnStartupNotifier.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final result = await UpdateService.checkForUpdate();
        if (!mounted) return;
        if (result.status == UpdateStatus.available && result.info != null) {
          showUpdatePrompt(context, result.info!);
        }
      } catch (_) {}
    });
  }

  Future<void> _maybeAutoScan() async {
    if (!autoScanNotifier.value) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt('last_scan_time') ?? 0;
      final days = autoScanDaysNotifier.value;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last > days * 24 * 3600 * 1000) {
        // 等 UI 就绪再扫
        await Future.delayed(const Duration(seconds: 2));
        if (mounted && !scanning) _scan();
      }
    } catch (_) {}
  }

  Future<void> _recordScanTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'last_scan_time',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  /// 节流更新扫描进度：变化超过 1% 或阶段变化时才 setState
  void _updateScanProgress(double p, String phase) {
    if (!mounted) return;
    final np = p.clamp(0.0, 1.0);
    if ((np - scanProgress).abs() >= 0.01 || scanPhase != phase) {
      setState(() {
        scanProgress = np;
        scanPhase = phase;
      });
    }
  }

  /// 扫描范围指纹：范围、短音频开关或假无损开关变化则缓存失效，走全量扫描。
  String _scanScopeKey() {
    final base = scanAllDirsNotifier.value
        ? 'all'
        : 'dirs:${(List<String>.from(scanDirsNotifier.value)..sort()).join(',')}';
    var key = includeShortSongsNotifier.value ? '$base+short' : base;
    if (spectralEnabledNotifier.value) key = '$key+spectral';
    return key;
  }

  Future<void> _scan() async {
    final totalSw = Stopwatch()..start();
    final stageMs = <String, int>{};
    var newOrChanged = -1;
    setState(() {
      scanning = true;
      status = '正在扫描媒体库...';
      scanProgress = 0;
      scanPhase = '扫描媒体库';
      groups = [];
      selections.clear();
    });
    try {
      // 先读缓存：供原生跳过未变文件（只读新增/变更的元数据），
      // 也供增量分组复用旧组。
      final scopeKey = _scanScopeKey();
      var sw = Stopwatch()..start();
      final cache = await ScanCache.load(scopeKey);
      stageMs['cacheLoadMs'] = sw.elapsedMilliseconds;
      final cachedSongs = cache == null
          ? null
          : {for (final s in cache.allFiles) s.path: s};

      sw = Stopwatch()..start();
      // 媒体库扫描占大头：原生进度 0→60%，让进度条一直走、不停在 0。
      // walk=遍历目录（约占媒体扫描九成时间）映射到 0-50%，
      // meta=读元数据映射到 50-60%。
      final all = await scanner.scanAll(
        includeShort: includeShortSongsNotifier.value,
        cachedSongs: cachedSongs,
        onMediaProgress: (stage, fraction, processed, total) {
          final overall = stage == 'walk'
              ? 0.5 * fraction
              : 0.5 + 0.1 * fraction;
          final label = stage == 'walk' ? '正在查找文件' : '扫描媒体库';
          _updateScanProgress(overall, label);
        },
      );
      stageMs['mediaScanMs'] = sw.elapsedMilliseconds;
      allSongs = all;
      totalSongs = all.length;
      // Tier 1~3 在后台 isolate 跑，界面保持响应
      _updateScanProgress(0.6, '标题时长分组');

      // 增量扫描：有缓存时只对新增/变更文件分组，旧组直接复用；
      // 无缓存（首次 / 范围变化 / 手动清除）走全量扫描。
      // 后续阶段占 60%→100%。
      List<DuplicateGroup> allGroups;
      if (cache == null) {
        allGroups = await SimilarityService.groupSimilarSongsWithFingerprint(
          all,
          enableFingerprint: fingerprintEnabledNotifier.value,
          enableCrossLingual: crossLingualEnabledNotifier.value,
          enableSpectral: spectralEnabledNotifier.value,
          onProgress: (done, total) {
            _updateScanProgress(
                0.6 + 0.4 * (done / (total == 0 ? 1 : total)), '文件指纹分析');
          },
          onChromaProgress: (done, total) {
            _updateScanProgress(
                0.6 + 0.4 * (done / (total == 0 ? 1 : total)), '声学细分');
          },
          onSpectralProgress: (done, total) {
            _updateScanProgress(
                0.6 + 0.4 * (done / (total == 0 ? 1 : total)), '频谱分析');
          },
          stageMs: stageMs,
        );
      } else {
        final diff = ScanCache.splitNewVsOld(all, cache.allFiles);
        newOrChanged = diff.changed.length;
        final byPath = {for (final s in all) s.path: s};
        final changedPaths = diff.changed.map((s) => s.path).toSet();
        final oldGroups = ScanCache.refreshGroups(
          cache.groups,
          byPath,
          changedPaths,
        );
        if (diff.changed.isEmpty) {
          // 无新增/变更：旧组即最终结果，跳过分组计算
          allGroups = oldGroups;
        } else {
          allGroups = await SimilarityService.groupIncremental(
            newSongs: diff.changed,
            oldSongs: diff.unchanged,
            oldGroups: oldGroups,
            enableFingerprint: fingerprintEnabledNotifier.value,
            enableCrossLingual: crossLingualEnabledNotifier.value,
            enableSpectral: spectralEnabledNotifier.value,
            onProgress: (done, total) {
              _updateScanProgress(
                  0.6 + 0.4 * (done / (total == 0 ? 1 : total)), '文件指纹分析');
            },
            onChromaProgress: (done, total) {
              _updateScanProgress(
                  0.6 + 0.4 * (done / (total == 0 ? 1 : total)), '声学细分');
            },
            onSpectralProgress: (done, total) {
              _updateScanProgress(
                  0.6 + 0.4 * (done / (total == 0 ? 1 : total)), '频谱分析');
            },
            stageMs: stageMs,
          );
        }
      }

      final g = allGroups
          // 跳过用户标记"不是重复"的分组
          .where((grp) => !IgnoreService.isIgnored(grp.key))
          .toList();
      final keepN = keepBestNotifier.value;
      sw = Stopwatch()..start();
      for (final grp in g) {
        // 同名不同版本组不自动勾选，用户手动决定
        selections[grp.key] = grp.noAutoSelect
            ? <String>{}
            : QualityService.autoSelectByRule(
                grp.songs,
                keepBest: keepN,
                rule: keepRuleNotifier.value,
                preferredDir: keepDirNotifier.value,
              );
      }
      stageMs['autoSelectMs'] = sw.elapsedMilliseconds;
      // 保存扫描结果（过滤前，含被忽略的组——取消忽略后重扫能恢复）
      sw = Stopwatch()..start();
      await ScanCache.save(
        groups: allGroups,
        selections: selections,
        scopeKey: scopeKey,
        totalSongs: totalSongs,
        allSongs: all,
      );
      stageMs['cacheSaveMs'] = sw.elapsedMilliseconds;
      stageMs['totalMs'] = totalSw.elapsedMilliseconds;
      // 写扫描历史文本报告（供调试核验，adb 可直接读取）
      await ScanHistoryService.record(
        groups: g,
        selections: selections,
        totalSongs: totalSongs,
        scopeKey: scopeKey,
        stageMs: stageMs,
        newOrChanged: newOrChanged,
        includeShort: includeShortSongsNotifier.value,
        allSongs: allSongs,
      );
      setState(() {
        groups = g;
        status = g.isEmpty ? '未发现重复（共 $totalSongs 首）' : '发现 ${g.length} 组重复';
      });
      // 扫描后后台批量检测封面/歌词
      _batchMediaTagsCheck();
      debugPrint(
        '[song_dedup] scan done: ${g.length} groups, total=$totalSongs',
      );
      _recordScanTime();
      for (final grp in g.take(5)) {
        debugPrint(
          '[song_dedup] group reason=${grp.reason} '
          'songs=${grp.songs.map((s) => '${s.displayName}@${s.bitrateKbps}kbps').toList()}',
        );
      }
    } catch (e) {
      setState(() => status = '扫描失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描失败: $e')));
      }
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  /// 扫描后批量检测封面/歌词：后台逐个查，结果打标签。结果进 MediaTagsCache 持久化。
  Future<void> _batchMediaTagsCheck() async {
    if (groups.isEmpty) return;
    final targets = <SongFile>[];
    for (final g in groups) {
      for (final s in g.songs) {
        if (!hasCoverMap.containsKey(s.path) ||
            !hasLyricsMap.containsKey(s.path)) {
          targets.add(s);
        }
      }
    }
    if (targets.isEmpty) return;
    final cache = await MediaTagsCache.load();
    try {
      for (final s in targets) {
        if (!mounted) return;
        var r = cache.get(s.path, s.sizeBytes);
        r ??= await MediaTagsService.checkTags(s.id, s.path);
        if (r != null) {
          await cache.put(s.path, s.sizeBytes, r['hasCover']!, r['hasLyrics']!);
          if (mounted) {
            setState(() {
              hasCoverMap[s.path] = r!['hasCover']!;
              hasLyricsMap[s.path] = r['hasLyrics']!;
            });
          }
        }
        await Future.delayed(const Duration(milliseconds: 30));
      }
    } finally {}
  }

  /// 清理报告文本：删除清单 + 释放空间，供系统分享。
  String _buildDeleteReport(List<TrashRecord> records) {
    final buf = StringBuffer();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    buf.writeln('清聆 清理报告');
    buf.writeln(
      '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}',
    );
    final freed = records.fold(0, (p, e) => p + e.size);
    buf.writeln('共删除 ${records.length} 个文件，释放 ${_fmt(freed)}');
    buf.writeln('---');
    for (final r in records) {
      buf.writeln('${r.name} | ${_fmt(r.size)} | ${r.originalPath}');
    }
    return buf.toString();
  }

  int get totalSelected => selections.values.fold(0, (p, e) => p + e.length);

  int get totalSelectedBytes {
    int s = 0;
    for (final g in groups) {
      final sel = selections[g.key] ?? {};
      for (final f in g.songs) {
        if (sel.contains(f.path)) s += f.sizeBytes;
      }
    }
    return s;
  }

  List<DuplicateGroup> get filtered {
    var list = groups
        .where(
          (g) =>
              searchQuery.isEmpty ||
              g.displayTitle.toLowerCase().contains(searchQuery.toLowerCase()),
        )
        .where((g) => _matchReasonFilter(g.reason))
        .toList();
    if (sortBy == 'size') {
      list.sort((a, b) => b.totalSize.compareTo(a.totalSize));
    } else if (sortBy == 'free') {
      list.sort((a, b) => _freeOf(b).compareTo(_freeOf(a)));
    } else {
      list.sort((a, b) => b.songs.length.compareTo(a.songs.length));
    }
    return list;
  }

  /// 筛选 chips 的原因映射：标题一致=同曲重复的各原因；不同版本=同名不同版本
  bool _matchReasonFilter(String reason) {
    return switch (reasonFilter) {
      '标题一致' => reason != '同名不同版本',
      '不同版本' => reason == '同名不同版本',
      _ => true,
    };
  }

  /// 该组已勾选（待删除）文件的总大小，即可释放空间。
  int _freeOf(DuplicateGroup g) {
    final sel = selections[g.key];
    if (sel == null || sel.isEmpty) return 0;
    return g.songs
        .where((s) => sel.contains(s.path))
        .fold(0, (p, e) => p + e.sizeBytes);
  }

  void _toggle(SongFile s, String key, bool v) {
    setState(() {
      // 点复选框选中时自动进入多选模式；取消选中不退出
      if (v && !multiSelectMode) multiSelectMode = true;
      final set = selections[key] ?? <String>{};
      if (v) {
        set.add(s.path);
      } else {
        set.remove(s.path);
      }
      selections[key] = set;
    });
  }

  /// 长按进入多选模式
  void _enterMultiSelect() {
    if (!multiSelectMode) setState(() => multiSelectMode = true);
  }

  void _exitMultiSelect() {
    if (multiSelectMode) setState(() => multiSelectMode = false);
  }

  /// 智能选中：按保留规则自动勾选（原顶部按钮逻辑，原样保留）
  void _smartSelect() {
    setState(() {
      final keepN = keepBestNotifier.value;
      for (final g in groups) {
        selections[g.key] = g.noAutoSelect
            ? <String>{}
            : QualityService.autoSelectByRule(
                g.songs,
                keepBest: keepN,
                rule: keepRuleNotifier.value,
                preferredDir: keepDirNotifier.value,
              );
      }
    });
  }

  /// 清空选择（原顶部按钮逻辑，原样保留）
  void _clearSelections() {
    setState(() => selections.updateAll((k, v) => <String>{}));
  }

  Future<void> _ignoreGroup(DuplicateGroup g) async {
    await IgnoreService.ignore(g.key);
    if (!mounted) return;
    setState(() {
      groups.removeWhere((x) => x.key == g.key);
      selections.remove(g.key);
      status = '已忽略 1 组，剩余 ${groups.length} 组';
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已忽略该组，可在设置中恢复')));
  }

  void _showDetailsSheet(SongFile s) {
    showSongDetailsSheet(
      context,
      s,
      onPreview: () => _togglePreview(s),
      playing: _playingPath == s.path,
    );
  }

  /// 曲库统计：点汇总行弹出
  void _showStatsSheet() {
    final byLabel = <String, List<SongFile>>{};
    for (final s in allSongs) {
      byLabel.putIfAbsent(s.effectiveQualityLabel, () => []).add(s);
    }
    const order = ['无损', '高音质', '标准', '较差'];
    final totalBytes = allSongs.fold(0, (p, e) => p + e.sizeBytes);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '曲库统计',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _statRow('总歌曲', '$totalSongs 首 · ${_fmt(totalBytes)}'),
              _statRow('重复组', '${groups.length} 组'),
              const Divider(height: 20),
              for (final label in order)
                if (byLabel.containsKey(label))
                  _statRow(
                    label,
                    '${byLabel[label]!.length} 首 · ${_fmt(byLabel[label]!.fold(0, (p, e) => p + e.sizeBytes))}',
                  ),
              const Divider(height: 20),
              _statRow('已选删除', '$totalSelected 首'),
              _statRow('可释放', _fmt(totalSelectedBytes)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _keepRuleLabel() {
    return switch (keepRuleNotifier.value) {
      'lossless' => '优先保留无损',
      'dir' => '优先保留指定目录',
      _ => '音质优先',
    };
  }

  Future<void> _confirmDelete() async {
    // 收集待删文件（按分组）
    final toDelete = <DuplicateGroup, List<SongFile>>{};
    for (final gg in groups) {
      final sel = selections[gg.key] ?? {};
      final ds = gg.songs.where((x) => sel.contains(x.path)).toList();
      if (ds.isNotEmpty) toDelete[gg] = ds;
    }
    if (toDelete.isEmpty) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (c2, scroll) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '待删清单（${toDelete.values.fold(0, (p, e) => p + e.length)} 个，'
                      '释放 ${_fmt(totalSelectedBytes)}）',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c2, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(c2, true),
                    child: const Text('移至回收站'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '文件将移至回收站，可在 30 天内撤销恢复。每组保留规则：${_keepRuleLabel()}，每组保留 ${keepBestNotifier.value} 个。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scroll,
                children: [
                  for (final e in toDelete.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                      child: Text(
                        e.key.reason,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    for (final f in e.value)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.music_note_rounded, size: 20),
                        title: Text(
                          f.displayName,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${f.formattedSize} · ${f.formattedBitrate} · ${f.path}',
                          style: const TextStyle(fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final paths = <String>[];
    final ids = <int>[];
    for (final gg in groups) {
      final sel = selections[gg.key] ?? {};
      for (final s in gg.songs) {
        if (sel.contains(s.path)) {
          paths.add(s.path);
          ids.add(s.id);
        }
      }
    }
    // 安全删除：先备份到回收站再删除。
    // 只有成功备份的文件才删——没进回收站的绝不能动，
    // 否则一旦复制失败就是丢数据。
    final trashRecords = await TrashService.moveToTrash(paths);
    final okPaths = trashRecords.map((r) => r.originalPath).toSet();
    final delPaths = <String>[];
    final delIds = <int>[];
    for (var i = 0; i < paths.length; i++) {
      if (okPaths.contains(paths[i])) {
        delPaths.add(paths[i]);
        delIds.add(ids[i]);
      }
    }
    final deleted = await DeleteService.deleteFiles(delPaths, delIds);
    if (deleted.isEmpty) {
      // 用户取消了系统删除确认：回滚回收站，
      // 避免留下"没删掉"的幽灵记录
      await TrashService.discardRecords(trashRecords);
      return;
    }
    // 删除成功：先把被删的歌存一份删除备份到导出清单，
    // 之后可从清单里恢复回收站里的歌。
    final deletedSongs = toDelete.values
        .expand((e) => e)
        .where((s) => deleted.contains(s.path))
        .toList();
    await ExportListService.saveSongs(deletedSongs, source: 'delete');
    if (!mounted) return;
    // 删掉的文件可能正在试听：停掉播放器并清掉试听状态
    await _player.stop();
    _previewTimer?.cancel();
    _playProgress.value = 0;
    setState(() {
      _playingPath = null;
      final ds = deleted.toSet();
      final ng = <DuplicateGroup>[];
      for (final gg in groups) {
        final rem = gg.songs.where((s) => !ds.contains(s.path)).toList();
        if (rem.length >= 2) {
          ng.add(
            DuplicateGroup(
              key: gg.key,
              songs: QualityService.sortByQualityDesc(rem),
              displayTitle: gg.displayTitle,
              reason: gg.reason,
            ),
          );
        }
        selections[gg.key]?.removeAll(ds);
      }
      groups = ng;
      status = '已移至回收站 ${deleted.length} 个，剩余 ${groups.length} 组';
    });
    final exportPath = await TrashService.exportList(trashRecords);
    if (!mounted) return;
    final deletedSet = deleted.toSet();
    final deletedRecords = trashRecords
        .where((r) => deletedSet.contains(r.originalPath))
        .toList();
    final freedBytes = deletedRecords.fold(0, (p, e) => p + e.size);
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('已移至回收站'),
        content: Text(
          '共 ${deleted.length} 个文件，预计释放 ${_fmt(freedBytes)}。'
          '${exportPath != null ? '\n清单已导出到 Download/清聆_回收站。' : ''}'
          '\n删除备份已保存，可在导出清单中查看并恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(c);
              final n = await TrashService.restoreLastBatch();
              if (!mounted) return;
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(n > 0 ? '已撤销 $n 个，请重新扫描' : '无可撤销')),
              );
            },
            child: const Text('撤销'),
          ),
          TextButton(
            onPressed: () => ShareService.shareText(
              _buildDeleteReport(deletedRecords),
              title: '分享清理报告',
            ),
            child: const Text('导出报告'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = filtered;
    // 返回键：多选模式先退出多选；结果页回到空状态，而非直接退出应用
    return PopScope(
      canPop: groups.isEmpty && !multiSelectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (multiSelectMode) {
          _exitMultiSelect();
        } else if (groups.isNotEmpty) {
          setState(() {
            groups = [];
            selections.clear();
            multiSelectMode = false;
            status = '准备就绪';
          });
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(scheme),
              Expanded(
                child: scanning
                    ? _buildScanning()
                    : groups.isEmpty
                    ? _buildEmpty(scheme)
                    : _buildResults(scheme, list),
              ),
            ],
          ),
        ),
        bottomNavigationBar: (groups.isEmpty || scanning)
            ? null
            : _buildBottomBar(scheme),
      ),
    );
  }

  /// 扫描中：进度显示（原 build 内联 UI，原样搬运）
  Widget _buildScanning() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              totalSongs > 0 ? '共 $totalSongs 首' : '正在扫描...',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: scanProgress > 0 ? scanProgress : null,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              scanPhase,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏：左"清聆"大标题（字间距拉开），右回收站 + 设置两个扁平圆按钮
  Widget _buildTopBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
      child: Row(
        children: [
          const Text(
            '清聆',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 5,
            ),
          ),
          const Spacer(),
          MinimalIconButton(
            icon: Icons.recycling_rounded,
            tooltip: '回收站',
            size: 38,
            iconSize: 19,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TrashScreen()),
            ),
          ),
          const SizedBox(width: 10),
          MinimalIconButton(
            icon: Icons.settings_rounded,
            tooltip: '设置',
            size: 38,
            iconSize: 19,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                      dirGroups: groups,
                      totalBytes: allSongs.fold<int>(
                          0, (a, s) => a + s.sizeBytes),
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 数据总览：一行文字，数字加粗，点击弹出曲库统计（原汇总行逻辑保留）
  Widget _buildStatsLine(ColorScheme scheme) {
    return InkWell(
      onTap: _showStatsSheet,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            children: [
              const TextSpan(text: '共 '),
              TextSpan(
                text: '$totalSongs',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const TextSpan(text: ' 首 · '),
              TextSpan(
                text: '${groups.length}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const TextSpan(text: ' 组重复 · 可释放 '),
              TextSpan(
                text: _fmt(totalSelectedBytes),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标签排：普通模式=筛选 chips；多选模式=智能选中/清空/退出多选（同一样式）
  Widget _buildChipRow(ColorScheme scheme) {
    if (multiSelectMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Row(
          children: [
            MinimalChip(label: '智能选中', selected: true, onTap: _smartSelect),
            const SizedBox(width: 8),
            MinimalChip(
              label: '清空',
              selected: false,
              enabled: totalSelected > 0,
              onTap: _clearSelections,
            ),
            const SizedBox(width: 8),
            MinimalChip(
              label: '退出多选',
              selected: false,
              onTap: _exitMultiSelect,
            ),
          ],
        ),
      );
    }
    const filters = ['全部', '标题一致', '不同版本'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          for (int i = 0; i < filters.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            MinimalChip(
              label: filters[i],
              selected: reasonFilter == filters[i],
              onTap: () => setState(() => reasonFilter = filters[i]),
            ),
          ],
        ],
      ),
    );
  }

  /// 搜索 + 排序（原功能保留，极简样式）
  Widget _buildSearchRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索歌曲/歌手…',
                hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: scheme.outline,
                ),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16),
                        onPressed: () => setState(() => searchQuery = ''),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => setState(() => searchQuery = v),
            ),
          ),
          const SizedBox(width: 4),
          _SortMenuButton(
            value: sortBy,
            onChanged: (v) => setState(() => sortBy = v),
          ),
        ],
      ),
    );
  }

  /// 底部栏：已选 N 首 + 刷新（浅灰圆）+ 删除（黑圆），刷新紧挨删除
  Widget _buildBottomBar(ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Text(
              '已选 ',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            Text(
              '$totalSelected',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            Text(
              ' 首',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            MinimalIconButton(
              icon: Icons.refresh_rounded,
              tooltip: '重新扫描',
              size: 46,
              iconSize: 22,
              onPressed: _scan,
            ),
            const SizedBox(width: 12),
            if (totalSelected > 0)
              MinimalIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: '移至回收站',
                size: 46,
                iconSize: 22,
                dark: true,
                onPressed: _confirmDelete,
              ),
          ],
        ),
      ),
    );
  }

  /// 空状态：黑白极简。灰色圆角音乐图标 + 标题 + 副标题 + 黑色 pill 扫描按钮。
  Widget _buildEmpty(ColorScheme scheme) {
    final bool isNoDup =
        totalSongs > 0 && groups.isEmpty && status.contains('未发现');
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: secondaryFillColor(context),
                borderRadius: BorderRadius.circular(22),
                border: dark
                    ? Border.all(color: scheme.outlineVariant, width: 1)
                    : null,
              ),
              child: Icon(
                isNoDup ? Icons.check_rounded : Icons.music_note_rounded,
                size: 32,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isNoDup ? '没有重复项目' : '发现重复歌曲',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              isNoDup ? '已扫描 $totalSongs 首，未发现重复歌曲。' : status,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: _scan,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: primaryFillColor(context),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isNoDup ? Icons.refresh_rounded : Icons.radar_rounded,
                      size: 16,
                      color: onPrimaryFillColor(context),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isNoDup ? '重新扫描' : '扫描相似歌曲',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: onPrimaryFillColor(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ColorScheme scheme, List<DuplicateGroup> list) {
    // 统计/chips/搜索钉在顶部，不随滚动消失（顶栏已在外层）
    return Column(
      children: [
        Align(alignment: Alignment.centerLeft, child: _buildStatsLine(scheme)),
        _buildChipRow(scheme),
        _buildSearchRow(scheme),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: list.length,
            itemBuilder: (ctx, i) {
              final g = list[i];
              final sel = selections[g.key] ?? {};
              return GroupCard(
                key: ValueKey(g.key),
                group: g,
                selectedPaths: sel,
                onToggle: (s, v) => _toggle(s, g.key, v),
                onSelectWorst: () => setState(
                  () => selections[g.key] = QualityService.autoSelectByRule(
                    g.songs,
                    keepBest: keepBestNotifier.value,
                    rule: keepRuleNotifier.value,
                    preferredDir: keepDirNotifier.value,
                  ),
                ),
                onInvert: () => setState(() {
                  final all = g.songs.map((e) => e.path).toSet();
                  selections[g.key] = all.difference(sel);
                }),
                onIgnore: () => _ignoreGroup(g),
                onShowDetails: (s) => _showDetailsSheet(s),
                playingPath: _playingPath,
                playProgress: _playProgress,
                onPreview: _togglePreview,
                onCompare: () => _showCompareSheet(g),
                freeBytes: _freeOf(g),
                hasCover: hasCoverMap,
                hasLyrics: hasLyricsMap,
                multiSelectMode: multiSelectMode,
                onEnterMultiSelect: _enterMultiSelect,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 极简排序菜单按钮：点击弹出白卡菜单（1px 细边框 + 14px 圆角），
/// 选中项黑字加粗 + 右侧对勾，无灰底高亮。与设置页下拉框统一。
class _SortMenuButton extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _SortMenuButton({required this.value, required this.onChanged});

  static const _options = {
    'count': '按数量排序',
    'size': '按大小排序',
    'free': '按可释放空间排序',
  };

  Future<void> _showMenu(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final entries = _options.entries.toList();
    final result = await showMenu<String>(
      context: context,
      position: position,
      color: scheme.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant, width: 1),
      ),
      items: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const PopupMenuDivider(height: 1),
          PopupMenuItem<String>(
            value: entries[i].key,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entries[i].value,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: entries[i].key == value
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: entries[i].key == value
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (entries[i].key == value) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_rounded, size: 14, color: scheme.onSurface),
                ],
              ],
            ),
          ),
        ],
      ],
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '排序',
      child: InkWell(
        onTap: () => _showMenu(context),
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.sort_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
