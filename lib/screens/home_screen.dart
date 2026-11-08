import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import '../services/audio_scanner.dart';
import '../services/delete_service.dart';
import '../services/quality_service.dart';
import '../services/similarity_service.dart';
import '../services/trash_service.dart';
import '../widgets/group_card.dart';
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
  List<DuplicateGroup> groups = [];
  final Map<String, Set<String>> selections = {};
  int totalSongs = 0;
  String searchQuery = '';
  String sortBy = 'count'; // count | size

  // 试听
  final AudioPlayer _player = AudioPlayer();
  String? _playingPath;
  Timer? _previewTimer;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingPath = null);
      _previewTimer?.cancel();
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _previewTimer?.cancel();
    super.dispose();
  }

  Future<void> _togglePreview(SongFile s) async {
    try {
      if (_playingPath == s.path) {
        await _player.stop();
        setState(() => _playingPath = null);
        _previewTimer?.cancel();
        return;
      }
      await _player.stop();
      _previewTimer?.cancel();
      await _player.play(DeviceFileSource(s.path));
      setState(() => _playingPath = s.path);
      // 10s 自动停止
      _previewTimer = Timer(const Duration(seconds: 10), () async {
        await _player.stop();
        if (mounted) setState(() => _playingPath = null);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法试听: $e')),
      );
    }
  }

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      status = '正在扫描媒体库...';
      groups = [];
      selections.clear();
    });
    try {
      final all = await scanner.scanAll();
      totalSongs = all.length;
      setState(() => status = '已扫描 $totalSongs 首，正在分析...');
      await Future.delayed(const Duration(milliseconds: 200));
      setState(() => status = '文件指纹分析中… 0/${all.length}');
      final g = await SimilarityService.groupSimilarSongsWithFingerprint(
        all,
        enableFingerprint: fingerprintEnabledNotifier.value,
        onProgress: (done, total) {
          if (mounted) setState(() => status = '文件指纹分析中… $done/$total');
        },
      );
      for (final grp in g) {
        selections[grp.key] =
            QualityService.autoSelectWorst(grp.songs, keepBest: 1);
      }
      setState(() {
        groups = g;
        status = g.isEmpty
            ? '未发现重复（共 $totalSongs 首）'
            : '发现 ${g.length} 组重复';
      });
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

  int get totalWaste {
    int w = 0;
    for (final g in groups) {
      if (g.songs.length <= 1) continue;
      for (int i = 1; i < g.songs.length; i++) {
        w += g.songs[i].sizeBytes;
      }
    }
    return w;
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
    } else {
      list.sort((a, b) => b.songs.length.compareTo(a.songs.length));
    }
    return list;
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

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移至回收站'),
        content: Text(
          '将 $totalSelected 个文件移至回收站（可撤销），预计释放 ${_fmt(totalSelectedBytes)}。\n\n已自动勾选音质较差的版本，每组保留最佳。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('移至回收站'),
          ),
        ],
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
    // 安全删除：先备份到回收站再删除
    final trashRecords = await TrashService.moveToTrash(paths);
    final deleted = await DeleteService.deleteFiles(paths, ids);
    if (deleted.isEmpty || !mounted) return;
    setState(() {
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
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已移至回收站 ${deleted.length} 个${exportPath != null ? '，清单已导出' : ''}',
        ),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            final n = await TrashService.restoreLastBatch();
            if (!mounted) return;
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(n > 0 ? '已撤销 $n 个，请重新扫描' : '无可撤销')),
            );
          },
        ),
        showCloseIcon: true,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(status, style: const TextStyle(fontSize: 14)),
                  ],
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
                      label: Text('删除 $totalSelected'),
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
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: list.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) return _buildHeader(scheme);
        final g = list[i - 1];
        final sel = selections[g.key] ?? {};
        return GroupCard(
          group: g,
          selectedPaths: sel,
          onToggle: (s, v) => _toggle(s, g.key, v),
          onSelectWorst: () => setState(
            () => selections[g.key] =
                QualityService.autoSelectWorst(g.songs, keepBest: 1),
          ),
          onInvert: () => setState(() {
            final all = g.songs.map((e) => e.path).toSet();
            selections[g.key] = all.difference(sel);
          }),
          playingPath: _playingPath,
          onPreview: _togglePreview,
        );
      },
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 一行汇总：共 X 首 · Y 组重复 · 已选 Z 首 · 可释放 W
        Text(
          '共 $totalSongs 首 · ${groups.length} 组重复 · 已选 $totalSelected 首 · 可释放 ${_fmt(totalWaste)}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
              ],
            ),
          ],
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                for (final g in groups) {
                  selections[g.key] =
                      QualityService.autoSelectWorst(g.songs, keepBest: 1);
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
          ],
        ),
        const Divider(height: 8),
        const SizedBox(height: 4),
      ],
    );
  }
}
