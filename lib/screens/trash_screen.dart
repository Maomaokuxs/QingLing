import 'package:flutter/material.dart';

import '../services/trash_service.dart';

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
      appBar: AppBar(
        title: const Text('回收站', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (records.isNotEmpty)
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_forever_rounded),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.recycling_rounded,
                          size: 56, color: scheme.outline),
                      const SizedBox(height: 12),
                      Text('回收站为空',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text('删除的歌曲将移至此处，可恢复或永久删除',
                          style: TextStyle(fontSize: 12, color: scheme.outline)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final r = records[i];
                    return ListTile(
                      leading: const Icon(Icons.music_note_rounded),
                      title: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${TrashService.formatSize(r.size)} · ${_fmtTime(r.time)}\n${r.originalPath}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '恢复',
                            icon: Icon(Icons.restore_rounded,
                                color: Colors.green.shade700),
                            onPressed: () => _restore(r),
                          ),
                          IconButton(
                            tooltip: '永久删除',
                            icon: Icon(Icons.delete_forever_rounded,
                                color: Colors.red.shade700),
                            onPressed: () => _deletePermanent(r),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
