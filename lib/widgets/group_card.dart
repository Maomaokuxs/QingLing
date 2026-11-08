import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';

/// 重复组卡片：标题 + 文件列表。保持朴素，不做装饰。
class GroupCard extends StatelessWidget {
  final DuplicateGroup group;
  final Set<String> selectedPaths;
  final void Function(SongFile, bool) onToggle;
  final VoidCallback onSelectWorst;
  final VoidCallback onInvert;
  final String? playingPath;
  final void Function(SongFile) onPreview;

  const GroupCard({
    super.key,
    required this.group,
    required this.selectedPaths,
    required this.onToggle,
    required this.onSelectWorst,
    required this.onInvert,
    required this.playingPath,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                          '${group.songs.length} 个版本 · ${group.reason} · 保留${group.best.extension.toUpperCase()}',
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
                  tooltip: '批量选择',
                  onSelected: (v) {
                    if (v == 'worst') onSelectWorst();
                    if (v == 'invert') onInvert();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'worst', child: Text('仅选最差')),
                    PopupMenuItem(value: 'invert', child: Text('反选')),
                  ],
                ),
              ],
            ),
            const Divider(height: 8),
            ...group.songs.map((s) {
              final checked = selectedPaths.contains(s.path);
              final isBest = s.path == group.best.path;
              final isWorst = s.path == group.worst.path;
              final playing = playingPath == s.path;
              return CheckboxListTile(
                value: checked,
                onChanged: (v) => onToggle(s, v ?? false),
                dense: true,
                activeColor: scheme.error,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  s.displayName,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${s.extension.toUpperCase()} · ${s.formattedBitrate} · ${s.formattedSize} · ${s.formattedDuration}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                secondary: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    IconButton(
                      tooltip: playing ? '停止试听' : '试听 10 秒',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        playing
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline_rounded,
                        color: playing
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      onPressed: () => onPreview(s),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
