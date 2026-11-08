import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/song_file.dart';
import '../services/audio_details_service.dart';
import '../services/spectrum_cache.dart';

/// 文件详情 BottomSheet：完整元数据 + 假无损频谱检测（仅无损文件）。
Future<void> showSongDetailsSheet(
  BuildContext context,
  SongFile s, {
  required VoidCallback onPreview,
  required bool playing,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _SongDetailsSheet(
      song: s,
      onPreview: onPreview,
      playing: playing,
    ),
  );
}

class _SongDetailsSheet extends StatefulWidget {
  final SongFile song;
  final VoidCallback onPreview;
  final bool playing;
  const _SongDetailsSheet({
    required this.song,
    required this.onPreview,
    required this.playing,
  });

  @override
  State<_SongDetailsSheet> createState() => _SongDetailsSheetState();
}

class _SongDetailsSheetState extends State<_SongDetailsSheet> {
  ({int sampleRate, int channels})? _details;
  // 频谱：idle / checking / done / failed
  String _specState = 'idle';
  Map<String, dynamic>? _specResult;

  @override
  void initState() {
    super.initState();
    _loadDetails();
    if (widget.song.qualityLabel == '无损') _runSpectrum();
  }

  Future<void> _loadDetails() async {
    final d = await AudioDetailsService.getDetails(widget.song.id, widget.song.path);
    if (mounted) setState(() => _details = d);
  }

  Future<void> _runSpectrum() async {
    setState(() => _specState = 'checking');
    Map<String, dynamic>? r;
    try {
      final cache = await SpectrumCache.load();
      r = cache.lookup(widget.song.path, widget.song.dateModified);
      r ??= await AudioDetailsService.analyzeSpectrum(widget.song.id, widget.song.path);
      if (r != null) {
        cache.store(widget.song.path, widget.song.dateModified, r);
        await cache.save();
      }
    } catch (_) {
      r = null;
    }
    if (!mounted) return;
    setState(() {
      _specResult = r;
      _specState = r == null ? 'failed' : 'done';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.song;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.displayName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '音质：${s.qualityLabel} · ${s.formattedBitrate}',
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
            if (s.qualityLabel == '无损') ...[
              const Divider(height: 24),
              _buildSpectrumRow(scheme),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onPreview();
                    },
                    icon: Icon(
                      widget.playing
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    label: Text(widget.playing ? '停止试听' : '试听 10 秒'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: s.path));
                      messenger.showSnackBar(
                        const SnackBar(content: Text('路径已复制')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('复制路径'),
                  ),
                ),
              ],
            ),
          ],
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

  Widget _buildSpectrumRow(ColorScheme scheme) {
    Widget status;
    switch (_specState) {
      case 'checking':
        status = const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('频谱分析中…', style: TextStyle(fontSize: 13)),
          ],
        );
      case 'done':
        final r = _specResult!;
        final suspect = AudioDetailsService.isFakeLosslessSuspect(r);
        final rolloff =
            ((r['rolloffHz'] as num).toDouble() / 1000).toStringAsFixed(1);
        status = Row(
          children: [
            Icon(
              suspect
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline_rounded,
              size: 16,
              color: suspect ? Colors.orange.shade800 : Colors.green.shade700,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                suspect
                    ? '疑似假无损：${rolloff}kHz 以上几乎无能量，可能是 MP3 转制'
                    : '真无损：有效频率达 ${rolloff}kHz',
                style: TextStyle(
                  fontSize: 13,
                  color: suspect ? Colors.orange.shade800 : null,
                  fontWeight: suspect ? FontWeight.bold : null,
                ),
              ),
            ),
          ],
        );
      case 'failed':
        status = const Text('检测失败：可能是不支持的编码', style: TextStyle(fontSize: 13));
      default:
        status = const Text('—', style: TextStyle(fontSize: 13));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              '频谱检测',
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: status),
        ],
      ),
    );
  }
}
