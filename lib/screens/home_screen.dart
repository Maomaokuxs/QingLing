import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import '../services/audio_details_service.dart';
import '../services/media_tags_service.dart';
import 'lrc_dedup_screen.dart';
import '../services/audio_scanner.dart';
import '../services/delete_service.dart';
import '../services/ignore_service.dart';
import '../services/quality_service.dart';
import '../services/share_service.dart';
import '../services/spectrum_cache.dart';
import '../services/similarity_service.dart';
import '../services/trash_service.dart';
import '../widgets/group_card.dart';
import '../widgets/song_details_sheet.dart';
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

  // 试听
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<double> _playProgress = ValueNotifier(0);
  // 调试通道：自动化测试用广播触发扫描，不影响正常使用
  static const _debugChannel = MethodChannel('song_dedup/debug');
  String? _playingPath;
  Timer? _previewTimer;
  // 假无损批量检测：path -> 是否疑似
  final Map<String, bool> spectrumSuspect = {};
  final Map<String, bool> hasCoverMap = {};
  final Map<String, bool> hasLyricsMap = {};
  bool spectrumScanning = false;
  String spectrumStatus = '';

  @override
  void initState() {
    super.initState();
    _maybeAutoScan();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法试听: $e')),
      );
    }
  }

  /// 对比试听专用：每次都从头播放（方便 AB 对比同一乐段），不做播放/停止切换。
  Future<void> _comparePlay(SongFile s) async {
    try {
      await _playFromStart(s);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法试听: $e')),
      );
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
                    style:
                        TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
                            selected: pickA?.path == s.path ||
                                pickB?.path == s.path,
                            selectedTileColor:
                                scheme.primary.withValues(alpha: 0.08),
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
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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
          'last_scan_time', DateTime.now().millisecondsSinceEpoch);
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

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      status = '正在扫描媒体库...';
      scanProgress = 0;
      scanPhase = '扫描媒体库';
      groups = [];
      selections.clear();
    });
    try {
      final all = await scanner.scanAll();
      allSongs = all;
      totalSongs = all.length;
      // Tier 1~3 在后台 isolate 跑，界面保持响应
      _updateScanProgress(0, '标题时长分组');

      final g = (await SimilarityService.groupSimilarSongsWithFingerprint(
        all,
        enableFingerprint: fingerprintEnabledNotifier.value,
        enableAcoustic: acousticFpEnabledNotifier.value,
        onProgress: (done, total) {
          // 文件指纹阶段：若同时开音频指纹占 0~60%，否则占 0~100%
          final end = acousticFpEnabledNotifier.value ? 0.6 : 1.0;
          _updateScanProgress(done / (total == 0 ? 1 : total) * end, '文件指纹分析');
        },
        onAcousticProgress: (done, total) {
          // 音频指纹阶段：若文件指纹也开了则从 60% 开始
          final start = fingerprintEnabledNotifier.value ? 0.6 : 0.0;
          _updateScanProgress(
              start + done / (total == 0 ? 1 : total) * (1.0 - start),
              '音频指纹分析');
        },
      ))
          // 跳过用户标记"不是重复"的分组
          .where((grp) => !IgnoreService.isIgnored(grp.key))
          .toList();
      final keepN = keepBestNotifier.value;
      for (final grp in g) {
        selections[grp.key] =
            QualityService.autoSelectByRule(grp.songs, keepBest: keepN,
              rule: keepRuleNotifier.value, preferredDir: keepDirNotifier.value);
      }
      setState(() {
        groups = g;
        status = g.isEmpty
            ? '未发现重复（共 $totalSongs 首）'
            : '发现 ${g.length} 组重复';
      });
      // 扫描后后台批量检测假无损
      _batchSpectrumCheck();
      // 扫描后后台批量检测封面/歌词
      _batchMediaTagsCheck();
      debugPrint('[song_dedup] scan done: ${g.length} groups, total=$totalSongs');
      _recordScanTime();
      for (final grp in g.take(5)) {
        debugPrint('[song_dedup] group reason=${grp.reason} '
            'songs=${grp.songs.map((s) => '${s.displayName}@${s.bitrateKbps}kbps').toList()}');
      }
    } catch (e) {
      setState(() => status = '扫描失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('扫描失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  /// 扫描后批量检测假无损：后台逐个解码无损文件，结果页打徽章。
  /// native 侧已在后台线程，结果进 SpectrumCache 持久化。
  Future<void> _batchSpectrumCheck() async {
    debugPrint('[song_dedup] batchSpectrum start enabled=${batchSpectrumNotifier.value} groups=${groups.length}');
    if (!batchSpectrumNotifier.value || groups.isEmpty) return;
    const losslessExts = {'flac', 'wav', 'aiff', 'aif', 'alac', 'ape'};
    final targets = <SongFile>[];
    for (final g in groups) {
      for (final s in g.songs) {
        if (losslessExts.contains(s.extension.toLowerCase())) targets.add(s);
      }
    }
    if (targets.isEmpty) return;
    debugPrint('[song_dedup] batchSpectrum targets=${targets.length}');
    final cache = await SpectrumCache.load();
    var done = 0;
    if (!mounted) return;
    setState(() {
      spectrumScanning = true;
      spectrumStatus = '假无损检测中 0/${targets.length}';
    });
    try {
      for (final s in targets) {
        if (!mounted) return;
        var r = cache.lookup(s.path, s.dateModified);
        debugPrint('[song_dedup] batchSpectrum analyzing ${s.displayName}');
        r ??= await AudioDetailsService.analyzeSpectrum(s.id, s.path);
        debugPrint('[song_dedup] batchSpectrum done ${s.displayName} r=${r != null}');
        if (r != null) {
          cache.store(s.path, s.dateModified, r);
          if (AudioDetailsService.isFakeLosslessSuspect(r)) {
            setState(() => spectrumSuspect[s.path] = true);
          }
        }
        done++;
        setState(() => spectrumStatus = '假无损检测中 $done/${targets.length}');
        // 让出 UI 线程
        await Future.delayed(const Duration(milliseconds: 30));
      }
      await cache.save();
    } finally {
      if (mounted) {
        setState(() {
          spectrumScanning = false;
          spectrumStatus = '';
        });
      }
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
          await cache.put(s.path, s.sizeBytes, r['hasCover']!,
              r['hasLyrics']!);
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

  /// 导出重复清单：文本格式
  String _buildDuplicateListText() {
    final buf = StringBuffer();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    buf.writeln('清聆 重复清单');
    buf.writeln(
        '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}');
    buf.writeln('共 ${groups.length} 组重复');
    buf.writeln('---');
    for (final g in groups) {
      buf.writeln('[${g.reason}] ${g.songs.length} 个版本');
      for (final f in g.songs) {
        buf.writeln('  ${f.displayName} | ${f.formattedBitrate} | ${f.formattedSize}');
        buf.writeln('  ${f.path}');
      }
      buf.writeln('');
    }
    return buf.toString();
  }

  /// 导出重复清单：M3U 播放列表格式
  String _buildDuplicateListM3u() {
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

  /// 按目录统计重复分布：目录 -> 文件数/占用空间
  Future<void> _showDirStats() async {
    if (groups.isEmpty || !mounted) return;
    final stats = <String, ({int count, int bytes})>{};
    for (final g in groups) {
      for (final f in g.songs) {
        final i = f.path.lastIndexOf('/');
        final dir = i > 0 ? f.path.substring(0, i) : '/';
        final e = stats[dir];
        stats[dir] = (
          count: (e?.count ?? 0) + 1,
          bytes: (e?.bytes ?? 0) + f.sizeBytes
        );
      }
    }
    final sorted = stats.entries.toList()
      ..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (c2, scroll) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('目录重复分布',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: sorted.length,
                itemBuilder: (c3, i) {
                  final e = sorted[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_rounded, size: 20),
                    title: Text(e.key,
                        style: const TextStyle(fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${e.value.count} 个重复文件 · 占用 ${_fmt(e.value.bytes)}',
                        style: const TextStyle(fontSize: 11)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportDuplicateList() async {
    if (groups.isEmpty || !mounted) return;
    final fmt = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('导出重复清单'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'text'),
            child: const Text('文本格式（.txt）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'm3u'),
            child: const Text('播放列表（.m3u）'),
          ),
        ],
      ),
    );
    if (fmt == null || !mounted) return;
    final content =
        fmt == 'm3u' ? _buildDuplicateListM3u() : _buildDuplicateListText();
    await ShareService.shareText(content,
        title: fmt == 'm3u' ? '分享重复清单（M3U）' : '分享重复清单');
  }

  /// 清理报告文本：删除清单 + 释放空间，供系统分享。
  String _buildDeleteReport(List<TrashRecord> records) {
    final buf = StringBuffer();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    buf.writeln('清聆 清理报告');
    buf.writeln(
        '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}');
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
      final set = selections[key] ?? <String>{};
      if (v) {
        set.add(s.path);
      } else {
        set.remove(s.path);
      }
      selections[key] = set;
    });
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已忽略该组，可在设置中恢复')),
    );
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
      byLabel.putIfAbsent(s.qualityLabel, () => []).add(s);
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
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c2, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: Colors.red),
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scroll,
                children: [
                  for (final e in toDelete.entries) ...[
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 8, 16, 2),
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
                        title: Text(f.displayName,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
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
    final deletedRecords =
        trashRecords.where((r) => deletedSet.contains(r.originalPath)).toList();
    final freedBytes = deletedRecords.fold(0, (p, e) => p + e.size);
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('已移至回收站'),
        content: Text(
          '共 ${deleted.length} 个文件，预计释放 ${_fmt(freedBytes)}。'
          '${exportPath != null ? '\n清单已导出到 Download/清聆_回收站。' : ''}',
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
    // 返回键：若在结果页则回到主界面（空状态），而非直接退出应用
    return PopScope(
      canPop: groups.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && groups.isNotEmpty) {
          setState(() {
            groups = [];
            selections.clear();
            status = '准备就绪';
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('清聆', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(
              tooltip: '回收站',
              icon: const Icon(Icons.recycling_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TrashScreen()),
              ),
            ),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: themeModeNotifier,
              builder: (context, mode, _) {
                final (icon, tip) = switch (mode) {
                  ThemeMode.light => (
                      Icons.light_mode_rounded,
                      '浅色模式（点击切为深色）'
                    ),
                  ThemeMode.dark => (
                      Icons.dark_mode_rounded,
                      '深色模式（点击切为跟随系统）'
                    ),
                  ThemeMode.system => (
                      Icons.brightness_auto_rounded,
                      '跟随系统（点击切为浅色）'
                    ),
                };
                return IconButton(
                  tooltip: tip,
                  icon: Icon(icon),
                  onPressed: () {
                    themeModeNotifier.value = switch (mode) {
                      ThemeMode.system => ThemeMode.light,
                      ThemeMode.light => ThemeMode.dark,
                      ThemeMode.dark => ThemeMode.system,
                    };
                  },
                );
              },
            ),
            IconButton(
              tooltip: '歌词去重',
              icon: const Icon(Icons.lyrics_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LrcDedupScreen()),
              ),
            ),
            IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
        ),
        body: scanning
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        totalSongs > 0 ? '共 $totalSongs 首' : '正在扫描...',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
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
                        scanPhase.isEmpty
                            ? ''
                            : '$scanPhase ${(scanProgress * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              )
            : groups.isEmpty
                ? _buildEmpty(scheme)
                : _buildResults(scheme, list),
        floatingActionButton: groups.isEmpty || scanning
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'refresh',
                    tooltip: '重新扫描',
                    onPressed: _scan,
                    child: const Icon(Icons.refresh_rounded),
                  ),
                  const SizedBox(width: 12),
                  if (totalSelected > 0)
                    FloatingActionButton.extended(
                      heroTag: 'delete',
                      onPressed: _confirmDelete,
                      icon: const Icon(Icons.delete_forever_rounded),
                      label: Text('移至回收站 $totalSelected'),
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    final bool isNoDup =
        totalSongs > 0 && groups.isEmpty && status.contains('未发现');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isNoDup ? Icons.check_circle_outline_rounded : Icons.library_music_rounded,
              size: 64,
              color: isNoDup ? Colors.green : scheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              isNoDup ? '没有重复项目' : '发现重复歌曲',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              isNoDup ? '已扫描 $totalSongs 首，未发现重复歌曲。' : status,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _scan,
              icon: Icon(isNoDup ? Icons.refresh_rounded : Icons.radar_rounded),
              label: Text(isNoDup ? '重新扫描' : '扫描相似歌曲'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ColorScheme scheme, List<DuplicateGroup> list) {
    // 搜索/汇总头钉在顶部，不随滚动消失
    return Column(
      children: [
        Container(
          color: scheme.surface,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: _buildHeader(scheme),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
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
                  () => selections[g.key] =
                      QualityService.autoSelectByRule(g.songs,
                          keepBest: keepBestNotifier.value,
                          rule: keepRuleNotifier.value,
                          preferredDir: keepDirNotifier.value),
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
                fakeLossless: spectrumSuspect,
                hasCover: hasCoverMap,
                hasLyrics: hasLyricsMap,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 一行汇总：点击弹出曲库统计
        InkWell(
          onTap: _showStatsSheet,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '共 $totalSongs 首 · ${groups.length} 组重复 · 已选 $totalSelected 首 · 可释放 ${_fmt(totalSelectedBytes)} ⓘ',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: InputDecoration(
                  hintText: '搜索歌曲/歌手…',
                  hintStyle:
                      TextStyle(fontSize: 13, color: scheme.outline),
                  prefixIcon:
                      Icon(Icons.search_rounded, size: 18, color: scheme.outline),
                  suffixIcon: searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 16),
                          onPressed: () =>
                              setState(() => searchQuery = ''),
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
            PopupMenuButton<String>(
              tooltip: '排序',
              icon: const Icon(Icons.sort_rounded),
              initialValue: sortBy,
              onSelected: (v) => setState(() => sortBy = v),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'count',
                  child: Text('按数量排序'),
                ),
                PopupMenuItem(
                  value: 'size',
                  child: Text('按大小排序'),
                ),
                PopupMenuItem(
                  value: 'free',
                  child: Text('按可释放空间排序'),
                ),
              ],
            ),
          ],
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                final keepN = keepBestNotifier.value;
                for (final g in groups) {
                  selections[g.key] =
                      QualityService.autoSelectByRule(g.songs, keepBest: keepN,
                      rule: keepRuleNotifier.value, preferredDir: keepDirNotifier.value);
                }
              }),
              icon: const Icon(Icons.auto_awesome_rounded, size: 16),
              label: const Text('智能选中', style: TextStyle(fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: totalSelected == 0
                  ? null
                  : () => setState(
                        () => selections.updateAll((k, v) => <String>{}),
                      ),
              icon: const Icon(Icons.deselect_rounded, size: 16),
              label: const Text('清空', style: TextStyle(fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: () => _exportDuplicateList(),
              icon: const Icon(Icons.share_rounded, size: 16),
              label: const Text('导出清单', style: TextStyle(fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: () => _showDirStats(),
              icon: const Icon(Icons.folder_rounded, size: 16),
              label: const Text('目录统计', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const Divider(height: 8),
        const SizedBox(height: 4),
      ],
    );
  }
}
