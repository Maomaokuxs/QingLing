import 'dart:io';

import 'package:flutter/material.dart';

import '../models/song_file.dart';
import '../services/export_list_service.dart';
import '../services/trash_service.dart';
import '../widgets/minimal_ui.dart';

/// 清单里一首歌的当前状态。
enum ExportSongStatus {
  /// 原路径文件还在 → 仍在曲库，不用恢复。
  inLibrary,

  /// 原路径没了、回收站有记录且回收站文件还在 → 可恢复。
  inTrash,

  /// 原路径没了、回收站也没有 → 无法恢复。
  gone,
}

/// 判定一首记录里的歌的当前状态。[trashByPath] 为原路径 -> 回收站记录
/// （同一原路径多条时取最新一条）；[exists] 为文件存在性判定，
/// 便于测试注入。
ExportSongStatus songStatus(
  SongFile s,
  Map<String, TrashRecord> trashByPath,
  bool Function(String path) exists,
) {
  if (exists(s.path)) return ExportSongStatus.inLibrary;
  final r = trashByPath[s.path];
  if (r != null && exists(r.trashPath)) return ExportSongStatus.inTrash;
  return ExportSongStatus.gone;
}

/// 清单详情页：一条导出记录里的全部歌曲，按状态排。
///
/// 在回收站的排前面、带「恢复」按钮；仍在曲库的只显示状态；
/// 已不在回收站的点一下会提示无法恢复。
class ExportListDetailScreen extends StatefulWidget {
  final ExportList list;

  const ExportListDetailScreen({super.key, required this.list});

  @override
  State<ExportListDetailScreen> createState() =>
      _ExportListDetailScreenState();
}

class _ExportListDetailScreenState extends State<ExportListDetailScreen> {
  /// 歌 -> 状态（恢复后重新计算）。
  Map<String, ExportSongStatus> statuses = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final trash = await TrashService.loadLog();
    // 同一原路径多条记录时取最新一条
    final trashByPath = <String, TrashRecord>{};
    for (final r in trash) {
      trashByPath[r.originalPath] = r;
    }
    final m = <String, ExportSongStatus>{};
    for (final s in widget.list.songs) {
      m[s.path] = songStatus(s, trashByPath, (p) => File(p).existsSync());
    }
    if (mounted) {
      setState(() {
        statuses = m;
        loading = false;
      });
    }
  }

  /// 恢复一首在回收站的歌。
  Future<void> _restore(SongFile s) async {
    final trash = await TrashService.loadLog();
    TrashRecord? record;
    for (final r in trash) {
      if (r.originalPath == s.path) record = r;
    }
    if (record == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该歌曲已不在回收站，无法恢复')));
      return;
    }
    final ok = await TrashService.restoreOne(record);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已恢复 ${s.displayName}' : '恢复失败')));
    if (ok) _load();
  }

  void _onTapGone(SongFile s) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${s.displayName} 已不在回收站，无法恢复')));
  }

  String _fmtTime(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 可恢复的排前面，其次仍在曲库，最后无法恢复；组内保持原顺序。
    final songs = [...widget.list.songs]..sort((a, b) {
        int rank(ExportSongStatus? s) => switch (s) {
              ExportSongStatus.inTrash => 0,
              ExportSongStatus.inLibrary => 1,
              _ => 2,
            };
        return rank(statuses[a.path]).compareTo(rank(statuses[b.path]));
      });
    final restorable =
        songs.where((s) => statuses[s.path] == ExportSongStatus.inTrash);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 4),
              child: Row(
                children: [
                  MinimalIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: '返回',
                    size: 38,
                    iconSize: 19,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _fmtTime(widget.list.savedAt),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  Text(
                    '${widget.list.songs.length} 首 · 占用 ${_fmtBytes(widget.list.totalSize)}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  if (restorable.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Text(
                      '其中 ${restorable.length} 首可在回收站恢复',
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.primary,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : songs.isEmpty
                      ? const Center(
                          child: Text('这条清单里没有歌曲',
                              style: TextStyle(fontSize: 13)),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                          itemCount: songs.length,
                          itemBuilder: (c, i) {
                            final s = songs[i];
                            final st = statuses[s.path];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: scheme.surface,
                                border: Border.all(
                                    color: scheme.outlineVariant, width: 1),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ListTile(
                                onTap: st == ExportSongStatus.gone
                                    ? () => _onTapGone(s)
                                    : null,
                                title: Text(s.displayName,
                                    style: const TextStyle(fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  '${s.artist.isNotEmpty ? s.artist : '未知歌手'} · ${_fmtBytes(s.sizeBytes)} · ${s.formattedBitrate}',
                                  style: const TextStyle(fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: switch (st) {
                                  ExportSongStatus.inTrash => FilledButton(
                                      onPressed: () => _restore(s),
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 6),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: const Text('恢复',
                                          style: TextStyle(fontSize: 12)),
                                    ),
                                  ExportSongStatus.inLibrary => Text('已在曲库',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: scheme.onSurfaceVariant)),
                                  _ => Text('无法恢复',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: scheme.onSurfaceVariant)),
                                },
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
