import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../services/export_list_service.dart';
import '../services/share_service.dart';
import '../widgets/minimal_ui.dart';
import 'export_list_detail_screen.dart';

/// 导出清单页：设置 → 工具 → 导出清单的唯一入口。
///
/// 顶部是「导出当前清单」：选格式分享，同时存一条快照；
/// 下面是历史清单记录，点一条进详情，可从回收站恢复其中的歌。
class ExportListsScreen extends StatefulWidget {
  /// 主屏当前重复分组（进设置页时的快照），用于导出当前清单。
  final List<DuplicateGroup> groups;

  const ExportListsScreen({super.key, this.groups = const []});

  @override
  State<ExportListsScreen> createState() => _ExportListsScreenState();
}

class _ExportListsScreenState extends State<ExportListsScreen> {
  List<ExportList> lists = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    lists = await ExportListService.loadAll();
    if (mounted) setState(() => loading = false);
  }

  /// 导出当前清单：本页内选格式，不弹回主页。
  Future<void> _exportCurrent() async {
    if (widget.groups.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无重复清单，请先扫描')));
      return;
    }
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
    // 先存清单快照（分享是否完成不可观测，存档不依赖分享结果）
    await ExportListService.save(widget.groups);
    final content = fmt == 'm3u'
        ? ExportListService.buildM3u(widget.groups)
        : ExportListService.buildText(widget.groups);
    await ShareService.shareText(
      content,
      title: fmt == 'm3u' ? '分享重复清单（M3U）' : '分享重复清单',
    );
    if (mounted) _load();
  }

  Future<void> _delete(ExportList list) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除清单'),
        content: Text(
          '将删除 ${_fmtTime(list.savedAt)} 的清单记录（${list.songs.length} 首），不影响曲库与回收站里的文件',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ExportListService.delete(list.id);
    if (mounted) _load();
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
    final songCount = widget.groups.fold(0, (p, g) => p + g.songs.length);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 导出清单（与关于页同款）
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
                  const Text(
                    '导出清单',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                      children: [
                        // 导出当前清单入口
                        Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            border: Border.all(
                              color: scheme.outlineVariant,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ListTile(
                            onTap: _exportCurrent,
                            leading: Icon(
                              Icons.ios_share_rounded,
                              size: 20,
                              color: scheme.primary,
                            ),
                            title: const Text(
                              '导出当前清单',
                              style: TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              widget.groups.isEmpty
                                  ? '暂无重复清单，请先扫描'
                                  : '${widget.groups.length} 组 · $songCount 首，导出为文本或播放列表并分享，同时保存一条清单记录',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                        // 历史清单
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                          child: Text(
                            '历史清单',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (lists.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                '暂无清单\n导出当前清单后，记录会留在这里',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 13, height: 1.8),
                              ),
                            ),
                          )
                        else
                          for (final list in lists)
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: scheme.surface,
                                border: Border.all(
                                  color: scheme.outlineVariant,
                                  width: 1,
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ListTile(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ExportListDetailScreen(list: list),
                                  ),
                                ).then((_) => _load()),
                                leading: Icon(
                                  Icons.list_alt_rounded,
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                ),
                                title: Text(
                                  _fmtTime(list.savedAt),
                                  style: const TextStyle(fontSize: 13),
                                ),
                                subtitle: Text(
                                  '${list.source == 'delete' ? '删除备份 · ' : ''}${list.songs.length} 首 · 占用 ${_fmtBytes(list.totalSize)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  tooltip: '删除清单',
                                  onPressed: () => _delete(list),
                                ),
                              ),
                            ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
