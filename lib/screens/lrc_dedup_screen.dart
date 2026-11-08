import 'package:flutter/material.dart';

import '../services/lrc_scanner.dart';

/// LRC 歌词去重页：按内容哈希找重复的 .lrc 文件
class LrcDedupScreen extends StatefulWidget {
  const LrcDedupScreen({super.key});

  @override
  State<LrcDedupScreen> createState() => _LrcDedupScreenState();
}

class _LrcDedupScreenState extends State<LrcDedupScreen> {
  bool scanning = true;
  String status = '正在扫描歌词文件...';
  List<List<LrcFile>> groups = [];
  final Map<int, Set<String>> selections = {}; // groupIndex -> paths

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      groups = [];
      selections.clear();
    });
    try {
      final g = await LrcScanner.findDuplicates(
        onProgress: (done, total) {
          if (mounted) setState(() => status = '比对中 $done/$total');
        },
      );
      if (!mounted) return;
      setState(() {
        groups = g;
        scanning = false;
        // 默认每组保留 1 个，选中其余
        for (var i = 0; i < g.length; i++) {
          if (g[i].length > 1) {
            selections[i] = g[i].skip(1).map((f) => f.path).toSet();
          }
        }
        status = g.isEmpty ? '未发现重复歌词' : '发现 ${g.length} 组重复歌词';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        scanning = false;
        status = '扫描失败：$e';
      });
    }
  }

  int get totalSelected =>
      selections.values.fold(0, (p, e) => p + e.length);

  Future<void> _confirmDelete() async {
    if (totalSelected == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除重复歌词'),
        content: Text('将删除 $totalSelected 个重复的 .lrc 文件（系统会弹出确认框）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final toDel = <LrcFile>[];
    for (var i = 0; i < groups.length; i++) {
      final sel = selections[i] ?? {};
      toDel.addAll(groups[i].where((f) => sel.contains(f.path)));
    }
    final success = await LrcScanner.deleteFiles(toDel);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? '已删除' : '删除失败或已取消')),
    );
    if (success) _scan();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词去重', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: '重新扫描',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: scanning ? null : _scan,
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
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lyrics_rounded,
                          size: 64, color: scheme.primary),
                      const SizedBox(height: 16),
                      Text(status, style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(status,
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        itemCount: groups.length,
                        itemBuilder: (ctx, i) {
                          final g = groups[i];
                          final sel = selections[i] ?? {};
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${g.first.displayName}（${g.length} 个相同）',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 4),
                                  for (final f in g)
                                    CheckboxListTile(
                                      dense: true,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      title: Text(f.path,
                                          style:
                                              const TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      subtitle: Text(f.formattedSize,
                                          style:
                                              const TextStyle(fontSize: 11)),
                                      value: sel.contains(f.path),
                                      onChanged: (v) => setState(() {
                                        final s = selections.putIfAbsent(
                                            i, () => <String>{});
                                        if (v == true) {
                                          s.add(f.path);
                                        } else {
                                          s.remove(f.path);
                                        }
                                      }),
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
      floatingActionButton: totalSelected > 0 && !scanning
          ? FloatingActionButton.extended(
              onPressed: _confirmDelete,
              icon: const Icon(Icons.delete_forever_rounded),
              label: Text('删除 $totalSelected'),
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            )
          : null,
    );
  }
}
