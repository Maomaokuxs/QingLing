import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/song_file.dart';
import '../services/audio_details_service.dart';
import '../services/lyrico_service.dart';
import 'minimal_ui.dart';

/// 文件详情 BottomSheet：完整元数据。
/// DraggableScrollableSheet 限高（60% 起、最大 85%），内容再长也不撑满全屏。
/// 顶部文件名截断 3 行；底部按钮固定，不随内容滚动。
Future<void> showSongDetailsSheet(
  BuildContext context,
  SongFile s, {
  required VoidCallback onPreview,
  required bool playing,
  VoidCallback? onLyricoSaved,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) => _SongDetailsSheet(
        song: s,
        onPreview: onPreview,
        playing: playing,
        onLyricoSaved: onLyricoSaved,
        scrollController: scrollController,
      ),
    ),
  );
}

class _SongDetailsSheet extends StatefulWidget {
  final SongFile song;
  final VoidCallback onPreview;
  final bool playing;
  final VoidCallback? onLyricoSaved;
  final ScrollController scrollController;
  const _SongDetailsSheet({
    required this.song,
    required this.onPreview,
    required this.playing,
    this.onLyricoSaved,
    required this.scrollController,
  });

  @override
  State<_SongDetailsSheet> createState() => _SongDetailsSheetState();
}

class _SongDetailsSheetState extends State<_SongDetailsSheet> {
  ({int sampleRate, int channels})? _details;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    final d = await AudioDetailsService.getDetails(widget.song.id, widget.song.path);
    if (mounted) setState(() => _details = d);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.song;
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              children: [
                // 超长文件名截断 3 行，完整标题仍在下方"标题"/"完整路径"可见。
                Text(
                  s.displayName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '音质：${s.effectiveQualityLabel} · ${s.formattedBitrate}${s.isFakeLossless ? ' · 疑似假无损（频谱截止 ${(s.spectral!.cutoffHz / 1000).toStringAsFixed(1)}kHz，约 ${s.spectral!.estimatedTrueBitrateKbps}kbps 来源）' : ''}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const Divider(height: 24),
                _row('标题', s.title.isNotEmpty ? s.title : '—'),
                _row('歌手', s.artist.isNotEmpty ? s.artist : '—'),
                _row('专辑', s.album.isNotEmpty ? s.album : '—'),
                _row('格式', s.extension.toUpperCase()),
                _row('码率', s.formattedBitrate),
                _row(
                  '采样率',
                  _details == null
                      ? '读取中…'
                      : AudioDetailsService.formatSampleRate(
                          _details!.sampleRate,
                        ),
                ),
                _row(
                  '声道',
                  _details == null
                      ? '读取中…'
                      : AudioDetailsService.formatChannels(_details!.channels),
                ),
                _row('时长', s.formattedDuration),
                _row('大小', s.formattedSize),
                _row('完整路径', s.path, copyable: true),
                const SizedBox(height: 12),
              ],
            ),
          ),
          // 固定底部按钮栏：不随内容滚动，任何时候可见。
          Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(
                top: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _pillButton(
                    dark: true,
                    icon: widget.playing
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    label: widget.playing ? '停止试听' : '试听 10 秒',
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onPreview();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _pillButton(
                    dark: false,
                    icon: Icons.copy_rounded,
                    label: '复制路径',
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: s.path));
                      messenger.showSnackBar(
                        const SnackBar(content: Text('路径已复制')),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _pillButton(
                    dark: false,
                    icon: Icons.edit_rounded,
                    label: 'Lyrico 编辑',
                    onPressed: _openLyrico,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 用 Lyrico 外部编辑打开这首歌（改标签、歌词、封面）。
  /// 保存返回后关掉详情页、通知主屏重扫（文件 mtime/size 已变，增量扫描会重读）；
  /// 未保存退出什么都不做；没装 Lyrico 时弹安装提示。
  /// 调起失败（通道异常）弹提示，不再静默无反应。
  Future<void> _openLyrico() async {
    late final LyricoEditResult result;
    try {
      result = await LyricoService.editSong(widget.song);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开 Lyrico 失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    switch (result) {
      case LyricoEditResult.saved:
        if (mounted) Navigator.pop(context);
        widget.onLyricoSaved?.call();
      case LyricoEditResult.cancelled:
        break;
      case LyricoEditResult.notInstalled:
        final go = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('未安装 Lyrico'),
            content: const Text('编辑标签、歌词需要安装 Lyrico（开源免费），去 GitHub 下载吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('去下载'),
              ),
            ],
          ),
        );
        if (go == true && mounted) {
          await LyricoService.openUrl(LyricoService.releaseUrl);
        }
    }
  }

  /// 极简 pill 按钮：dark=true 黑底白字，dark=false 灰底深字。
  Widget _pillButton({
    required bool dark,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: dark ? primaryFillColor(context) : secondaryFillColor(context),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: dark
                    ? onPrimaryFillColor(context)
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dark
                      ? onPrimaryFillColor(context)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onLongPress: copyable
                  ? () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: value));
                      messenger.showSnackBar(
                        const SnackBar(content: Text('路径已复制')),
                      );
                    }
                  : null,
              child: Text(
                value,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
