import 'package:flutter/material.dart';

import '../services/lrc_scanner.dart';
import '../widgets/minimal_ui.dart';

/// LRC 歌词去重页：按内容哈希找重复的 .lrc 文件（极简风 UI）。
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

  int get totalFiles => groups.fold(0, (p, g) => p + g.length);

  Future<void> _confirmDelete() async {
    if (totalSelected == 0) return;
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '删除重复歌词',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '将删除 $totalSelected 个重复的 .lrc 文件（系统会弹出确认框）。',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogAction(
                    label: '取消',
                    dark: false,
                    onTap: () => Navigator.pop(c, false),
                  ),
                  const SizedBox(width: 8),
                  _DialogAction(
                    label: '删除',
                    dark: true,
                    onTap: () => Navigator.pop(c, true),
                  ),
                ],
              ),
            ],
          ),
        ),
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

  /// 顶栏：返回 + "歌词去重"大标题 + 右侧刷新圆按钮
  Widget _buildTopBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
      child: Row(
        children: [
          MinimalIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: '返回',
            size: 38,
            iconSize: 19,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 10),
          const Text(
            '歌词去重',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
            ),
          ),
          const Spacer(),
          MinimalIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '重新扫描',
            size: 38,
            iconSize: 19,
            onPressed: scanning ? null : _scan,
          ),
        ],
      ),
    );
  }

  /// 统计行：X 组重复 · X 个文件，左对齐
  Widget _buildStatsLine(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            children: [
              TextSpan(
                text: '${groups.length}',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: ' 组重复 · '),
              TextSpan(
                text: '$totalFiles',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: ' 个文件'),
            ],
          ),
        ),
      ),
    );
  }

  /// 分组卡：扁平白卡 + 眉题 + 文件行
  Widget _buildGroupCard(ColorScheme scheme, int index) {
    final g = groups[index];
    final sel = selections[index] ?? {};
    final selectedCount = sel.length;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '内容完全相同',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            g.first.displayName,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${g.length} 个相同 · 已选中 $selectedCount 个待清理',
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          for (var i = 0; i < g.length; i++)
            _buildFileRow(scheme, index, g[i], i > 0),
        ],
      ),
    );
  }

  Widget _buildFileRow(
      ColorScheme scheme, int groupIndex, LrcFile f, bool showDivider) {
    final sel = selections[groupIndex] ?? {};
    final checked = sel.contains(f.path);
    return Container(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                top: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5)))
            : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          MinimalCheckbox(
            checked: checked,
            size: 20,
            onTap: () => setState(() {
              final s = selections.putIfAbsent(groupIndex, () => <String>{});
              if (checked) {
                s.remove(f.path);
              } else {
                s.add(f.path);
              }
            }),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.path,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  f.formattedSize,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 底部栏：已选 X 个 + 黑色删除圆按钮
  Widget _buildBottomBar(ColorScheme scheme) {
    if (totalSelected == 0 || scanning) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Text(
              '已选 ',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            Text(
              '$totalSelected',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            Text(
              ' 个',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            MinimalIconButton(
              icon: Icons.delete_rounded,
              tooltip: '删除',
              dark: true,
              size: 46,
              iconSize: 20,
              onPressed: _confirmDelete,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanning(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: primaryFillColor(context),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            status,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              Icons.lyrics_rounded,
              size: 32,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '歌词去重',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            status,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(scheme),
            if (scanning)
              Expanded(child: _buildScanning(scheme))
            else if (groups.isEmpty)
              Expanded(child: _buildEmpty(scheme))
            else ...[
              _buildStatsLine(scheme),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
                  itemCount: groups.length,
                  itemBuilder: (ctx, i) => Padding(
                    padding:
                        EdgeInsets.only(bottom: i < groups.length - 1 ? 10 : 0),
                    child: _buildGroupCard(scheme, i),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(scheme),
    );
  }
}

/// 对话框里的极简操作按钮：黑底 / 灰底 pill
class _DialogAction extends StatelessWidget {
  final String label;
  final bool dark;
  final VoidCallback onTap;

  const _DialogAction({
    required this.label,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color:
              dark ? primaryFillColor(context) : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color:
                dark ? onPrimaryFillColor(context) : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
