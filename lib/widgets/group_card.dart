import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';

/// 重复组卡片：标题 + 文件列表。保持朴素，不做装饰。
/// 组内歌曲多时默认收起只显示前 3 首，避免长组把页面拉得过长。
class GroupCard extends StatefulWidget {
  final DuplicateGroup group;
  final Set<String> selectedPaths;
  final void Function(SongFile, bool) onToggle;
  final VoidCallback onSelectWorst;
  final VoidCallback onInvert;
  final VoidCallback onIgnore;
  final void Function(SongFile) onShowDetails;
  final String? playingPath;
  final ValueNotifier<double> playProgress;
  final void Function(SongFile) onPreview;
  final VoidCallback onCompare;
  final int freeBytes;
  /// 假无损批量检测结果：path -> 是否疑似
  final Map<String, bool> fakeLossless;
  final Map<String, bool> hasCover;
  final Map<String, bool> hasLyrics;

  const GroupCard({
    super.key,
    required this.group,
    required this.selectedPaths,
    required this.onToggle,
    required this.onSelectWorst,
    required this.onInvert,
    required this.onIgnore,
    required this.onShowDetails,
    required this.playingPath,
    required this.playProgress,
    required this.onPreview,
    required this.onCompare,
    required this.freeBytes,
    this.fakeLossless = const {},
    this.hasCover = const {},
    this.hasLyrics = const {},
  });

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard> {
  static const _collapsedCount = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final group = widget.group;
    final songs = _expanded || group.songs.length <= _collapsedCount
        ? group.songs
        : group.songs.take(_collapsedCount).toList();
    final selectedInGroup =
        group.songs.where((s) => widget.selectedPaths.contains(s.path)).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 0, 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.displayTitle,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${group.songs.length} 个版本 · ${group.reason} · 保留${group.best.extension.toUpperCase()}${_freeSuffix()}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '批量操作',
                  onSelected: (v) {
                    if (v == 'worst') widget.onSelectWorst();
                    if (v == 'invert') widget.onInvert();
                    if (v == 'ignore') widget.onIgnore();
                    if (v == 'compare') widget.onCompare();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'worst', child: Text('仅选最差')),
                    PopupMenuItem(value: 'invert', child: Text('反选')),
                    PopupMenuItem(value: 'ignore', child: Text('忽略本组')),
                    PopupMenuItem(value: 'compare', child: Text('AB 对比试听')),
                  ],
                ),
              ],
            ),
            const Divider(height: 8),
            ...songs.map((s) => _buildSongRow(context, scheme, s)),
            if (!_expanded && group.songs.length > _collapsedCount)
              Center(
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = true),
                  icon: const Icon(Icons.expand_more_rounded, size: 16),
                  label: Text(
                    '展开全部 ${group.songs.length} 首（已选 $selectedInGroup）',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              )
            else if (_expanded && group.songs.length > _collapsedCount)
              Center(
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = false),
                  icon: const Icon(Icons.expand_less_rounded, size: 16),
                  label: const Text('收起', style: TextStyle(fontSize: 12)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _freeSuffix() => widget.freeBytes > 0
      ? ' · 可释放${_fmtBytes(widget.freeBytes)}'
      : '';

  Widget _buildSongRow(BuildContext context, ColorScheme scheme, SongFile s) {
    final checked = widget.selectedPaths.contains(s.path);
    final isBest = s.path == widget.group.best.path;
    final isWorst = s.path == widget.group.worst.path;
    final playing = widget.playingPath == s.path;
    return CheckboxListTile(
      value: checked,
      onChanged: (v) => widget.onToggle(s, v ?? false),
      dense: true,
      // 选中=待删除：整行给淡淡的红色底，一眼看清勾了哪些
      selected: checked,
      selectedTileColor: scheme.error.withValues(alpha: 0.07),
      activeColor: scheme.error,
      controlAffinity: ListTileControlAffinity.leading,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.displayName,
            style: const TextStyle(fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (playing)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ValueListenableBuilder<double>(
                valueListenable: widget.playProgress,
                builder: (_, p, _) => LinearProgressIndicator(
                  value: p,
                  minHeight: 2,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${s.extension.toUpperCase()} · ${s.formattedBitrate} · ${s.formattedSize} · ${s.formattedDuration}',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.fakeLossless[s.path] == true)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _warnColor(context).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 10,
                            color: _warnColor(context),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '疑似假无损',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: _warnColor(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (widget.hasCover[s.path] == true)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: _TagBadge(icon: Icons.image_rounded, label: '封面'),
                  ),
                if (widget.hasLyrics[s.path] == true)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: _TagBadge(icon: Icons.lyrics_rounded, label: '歌词'),
                  ),
                _QualityBadge(label: s.qualityLabel),
                const SizedBox(width: 4),
                if (isBest)
                  Text(
                    '最佳',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.green.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                else if (isWorst)
                  Text(
                    '最差',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      secondary: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '文件详情',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () => widget.onShowDetails(s),
          ),
          IconButton(
            tooltip: playing ? '停止试听' : '试听 10 秒',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              playing
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline_rounded,
              size: 20,
              color: playing ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: () => widget.onPreview(s),
          ),
        ],
      ),
    );
  }
}

/// 小标签徽章：封面 / 歌词，中性配色。
class _TagBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TagBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: c),
          const SizedBox(width: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.bold, color: c)),
        ],
      ),
    );
  }
}

/// 音质徽章：无损 / 高音质 / 标准 / 较差，朴素 pill 样式。
/// 深色模式用提亮后的配色，保证文字对比度。
class _QualityBadge extends StatelessWidget {
  final String label;
  const _QualityBadge({required this.label});

  Color _color(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (label) {
      '无损' => dark ? const Color(0xFF4CC38A) : const Color(0xFF0F9D58),
      '高音质' => dark ? const Color(0xFF8AB4F8) : const Color(0xFF4285F4),
      '标准' => dark ? const Color(0xFFFFC94D) : const Color(0xFF9A6B00),
      _ => dark ? const Color(0xFFF28B82) : const Color(0xFFC5221F),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = _color(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: c,
        ),
      ),
    );
  }
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

Color _warnColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFFFFB74D) : Colors.orange.shade800;
}
