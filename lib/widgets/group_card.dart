import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import 'minimal_ui.dart';

/// 重复组卡片：极简扁平风。
/// 白卡（深色下 surfaceContainer）+ 1px 细边框 + 20px 圆角，无阴影。
/// 顶部小字眉题（分组原因），下方歌名；歌曲行为扁平圆复选框 + 试听圆按钮。
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
  final Map<String, bool> hasCover;
  final Map<String, bool> hasLyrics;

  /// 多选模式：卡片描边加深，点歌曲行直接切换勾选
  final bool multiSelectMode;
  final VoidCallback onEnterMultiSelect;

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
    this.hasCover = const {},
    this.hasLyrics = const {},
    this.multiSelectMode = false,
    required this.onEnterMultiSelect,
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

    return GestureDetector(
      onLongPress: widget.onEnterMultiSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(
            color: widget.multiSelectMode
                ? scheme.onSurface
                : scheme.outlineVariant,
            width: widget.multiSelectMode ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 眉题：分组原因
                        Text(
                          group.reason,
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          group.displayTitle,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${group.songs.length} 首 · 保留${group.best.extension.toUpperCase()}${_freeSuffix()}',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _CardMenuButton(
                    onSelectWorst: widget.onSelectWorst,
                    onInvert: widget.onInvert,
                    onIgnore: widget.onIgnore,
                    onCompare: widget.onCompare,
                  ),
                ],
              ),
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

    void toggle() => widget.onToggle(s, !checked);

    return GestureDetector(
      onLongPress: () {
        widget.onEnterMultiSelect();
        if (!checked) widget.onToggle(s, true);
      },
      onTap: widget.multiSelectMode ? toggle : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
        child: Row(
          children: [
            MinimalCheckbox(checked: checked, onTap: toggle),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.displayName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${s.extension.toUpperCase()} · ${s.formattedBitrate} · ${s.formattedSize}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 音质：纯文字颜色，不做徽章
                      Text(
                        s.effectiveQualityLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: qualityTextColor(
                              context, s.effectiveQualityLabel),
                        ),
                      ),
                      if (s.isFakeLossless)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: _TagBadge(
                              icon: Icons.warning_amber_rounded,
                              label: '疑似假无损'),
                        ),
                      if (widget.hasCover[s.path] == true)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: _TagBadge(
                              icon: Icons.image_rounded, label: '封面'),
                        ),
                      if (widget.hasLyrics[s.path] == true)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: _TagBadge(
                              icon: Icons.lyrics_rounded, label: '歌词'),
                        ),
                      if (isBest)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '最佳',
                            style: TextStyle(
                              fontSize: 11,
                              color: qualityTextColor(context, '无损'),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      else if (isWorst)
                        Text(
                          '最差',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  if (playing)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ValueListenableBuilder<double>(
                        valueListenable: widget.playProgress,
                        builder: (_, p, _) => LinearProgressIndicator(
                          value: p,
                          minHeight: 2,
                          backgroundColor:
                              scheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 详情
            MinimalIconButton(
              icon: Icons.info_outline_rounded,
              onPressed: () => widget.onShowDetails(s),
              size: 32,
              iconSize: 17,
              tooltip: '文件详情',
            ),
            const SizedBox(width: 6),
            // 试听
            MinimalIconButton(
              icon: playing
                  ? Icons.stop_rounded
                  : Icons.play_arrow_rounded,
              onPressed: () => widget.onPreview(s),
              size: 32,
              iconSize: 17,
              tooltip: playing ? '停止试听' : '试听 10 秒',
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组卡右上角"..."菜单：极简风 showMenu，与排序菜单/设置下拉框统一。
/// 白卡 + 1px 细边框 + 14px 圆角，选项 12px 灰字，细分隔线，无灰底高亮。
/// 四个选项均为动作项（无选中态，不显示对勾）。
class _CardMenuButton extends StatelessWidget {
  final VoidCallback onSelectWorst;
  final VoidCallback onInvert;
  final VoidCallback onIgnore;
  final VoidCallback onCompare;

  const _CardMenuButton({
    required this.onSelectWorst,
    required this.onInvert,
    required this.onIgnore,
    required this.onCompare,
  });

  static const _options = [
    ('worst', '仅选最差'),
    ('invert', '反选'),
    ('ignore', '忽略本组'),
    ('compare', 'AB 对比试听'),
  ];

  Future<void> _showMenu(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
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
        for (var i = 0; i < _options.length; i++) ...[
          if (i > 0) const PopupMenuDivider(height: 1),
          PopupMenuItem<String>(
            value: _options[i].$1,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              _options[i].$2,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
    if (result == null) return;
    switch (result) {
      case 'worst':
        onSelectWorst();
      case 'invert':
        onInvert();
      case 'ignore':
        onIgnore();
      case 'compare':
        onCompare();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '批量操作',
      child: InkWell(
        onTap: () => _showMenu(context),
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.more_horiz_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 小标签：封面 / 歌词，中性配色。
class _TagBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TagBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 10, color: c),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 10, color: c)),
      ],
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
