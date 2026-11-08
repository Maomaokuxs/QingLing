import 'package:flutter/material.dart';

import '../services/trash_service.dart';
import '../widgets/minimal_ui.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashRecord> records = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    records = await TrashService.loadLog();
    records.sort((a, b) => b.time.compareTo(a.time));
    if (mounted) setState(() => loading = false);
  }

  Future<void> _restore(TrashRecord r) async {
    final ok = await TrashService.restoreOne(r);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ok ? '已恢复 ${r.name}' : '恢复失败')));
    if (ok) _load();
  }

  Future<void> _deletePermanent(TrashRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('永久删除'),
        content: Text('将永久删除 ${r.name}\n${r.originalPath}\n此操作不可撤销'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await TrashService.deletePermanentOne(r);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(res ? '已永久删除' : '删除失败')));
    if (res) _load();
  }

  Future<void> _clearAll() async {
    if (records.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空回收站'),
        content: Text('将永久删除回收站内 ${records.length} 个文件，不可恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await TrashService.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('回收站已清空')));
    _load();
  }

  String _fmtTime(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(scheme),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : records.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.recycling_rounded,
                                  size: 48, color: scheme.outlineVariant),
                              const SizedBox(height: 12),
                              Text('回收站为空',
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 4),
                              Text('删除的歌曲将移至此处，可恢复或永久删除',
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.outline)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding:
                              const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: records.length,
                          itemBuilder: (c, i) {
                            final r = records[i];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: scheme.surface,
                                border: Border.all(
                                    color: scheme.outlineVariant, width: 1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    16, 13, 12, 13),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w600),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${TrashService.formatSize(r.size)} · ${_fmtTime(r.time)}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            r.originalPath,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: scheme.outline,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    MinimalIconButton(
                                      icon: Icons.restore_rounded,
                                      tooltip: '恢复',
                                      size: 38,
                                      iconSize: 18,
                                      onPressed: () => _restore(r),
                                    ),
                                    const SizedBox(width: 8),
                                    MinimalIconButton(
                                      icon: Icons.delete_forever_rounded,
                                      tooltip: '永久删除',
                                      size: 38,
                                      iconSize: 18,
                                      dark: true,
                                      onPressed: () =>
                                          _deletePermanent(r),
                                    ),
                                  ],
                                ),
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

  /// 顶栏：返回 + "回收站"大标题 + 清空按钮，与主屏风格统一
  Widget _buildTopBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
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
            '回收站',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 5,
            ),
          ),
          const Spacer(),
          if (records.isNotEmpty)
            MinimalIconButton(
              icon: Icons.delete_sweep_rounded,
              tooltip: '清空回收站',
              size: 38,
              iconSize: 19,
              dark: true,
              onPressed: _clearAll,
            ),
        ],
      ),
    );
  }
}
