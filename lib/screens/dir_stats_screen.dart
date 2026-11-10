import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/duplicate_group.dart';
import '../widgets/minimal_ui.dart';

/// 目录统计页：按目录列出重复文件的分布与占用空间。
///
/// 独立页面（不是底部 sheet）：从设置页 push 进来，返回回到设置页，
/// 不跳回主页。数据由主屏传入当前分组列表。顶部饼图展示重复歌曲占用
/// 在全部歌曲占用中的比例（重复部分 vs 其余部分）。
class DirStatsScreen extends StatelessWidget {
  final List<DuplicateGroup> groups;
  final int? totalBytes;

  const DirStatsScreen({super.key, required this.groups, this.totalBytes});

  /// 重复文件总占用（组内全部文件大小之和，含最后会留下的那一份）。
  int _dupBytes() {
    var n = 0;
    for (final g in groups) {
      for (final f in g.songs) {
        n += f.sizeBytes;
      }
    }
    return n;
  }

  /// 按目录统计：目录 -> 文件数/占用空间，按占用空间从大到小排。
  List<MapEntry<String, ({int count, int bytes})>> _stats() {
    final stats = <String, ({int count, int bytes})>{};
    for (final g in groups) {
      for (final f in g.songs) {
        final i = f.path.lastIndexOf('/');
        final dir = i > 0 ? f.path.substring(0, i) : '/';
        final e = stats[dir];
        stats[dir] = (
          count: (e?.count ?? 0) + 1,
          bytes: (e?.bytes ?? 0) + f.sizeBytes
        );
      }
    }
    final sorted = stats.entries.toList()
      ..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = _stats();
    final total = totalBytes ?? 0;
    final dup = _dupBytes();
    final showPie = total > 0 && dup > 0;
    final dupFrac = showPie ? dup / total : 0.0;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 目录统计（与关于页同款）
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
                    '目录统计',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                    ),
                  ),
                ],
              ),
            ),
            // 圆环图卡片：重复歌曲占用 / 全部歌曲占用（圆环 + 牵引线标注 + 图例）
            if (showPie)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: scheme.outlineVariant, width: 1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: 210,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _DonutPainter(
                          dupFraction: dupFrac,
                          dupColor: scheme.primary,
                          otherColor: scheme.surfaceContainerHighest,
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface,
                            height: 1.3,
                          ),
                          lineColor: scheme.outline,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _LegendDot(color: scheme.primary, label: '重复歌曲'),
                        const SizedBox(width: 20),
                        _LegendDot(
                          color: scheme.surfaceContainerHighest,
                          label: '其他歌曲',
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '全部歌曲共 ${_fmt(total)}，其中重复歌曲 ${_fmt(dup)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: sorted.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无重复文件',
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                      itemCount: sorted.length,
                      itemBuilder: (c, i) {
                        final e = sorted[i];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            border: Border.all(
                                color: scheme.outlineVariant, width: 1),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ListTile(
                            leading: Icon(Icons.folder_rounded,
                                size: 20, color: scheme.onSurfaceVariant),
                            title: Text(e.key,
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '${e.value.count} 个重复文件 · 占用 ${_fmt(e.value.bytes)}',
                                style: const TextStyle(fontSize: 11)),
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
}

String _fmt(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 两瓣圆环图：重复部分从顶部顺时针画，其余部分为底色整环。
/// 每瓣中点引一条牵引线到环外，线上端标百分比与名称。
class _DonutPainter extends CustomPainter {
  final double dupFraction;
  final Color dupColor;
  final Color otherColor;
  final TextStyle labelStyle;
  final Color lineColor;

  const _DonutPainter({
    required this.dupFraction,
    required this.dupColor,
    required this.otherColor,
    required this.labelStyle,
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 环外半径 62、环宽 30，左右各留约 90px 给牵引线与文字。
    const ringOuter = 62.0;
    const ringWidth = 30.0;
    final ringR = ringOuter - ringWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: ringR);
    final otherPaint = Paint()
      ..color = otherColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth;
    canvas.drawCircle(center, ringR, otherPaint);
    if (dupFraction > 0) {
      final dupPaint = Paint()
        ..color = dupColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth;
      canvas.drawArc(rect, -math.pi / 2, dupFraction * 2 * math.pi, false,
          dupPaint);
    }
    // 牵引线标注：每瓣中点角出发，先沿径向出环，再横向一小段，文字贴在线端。
    _drawLabel(canvas, size, center, ringOuter,
        -math.pi / 2 + dupFraction * math.pi, '重复歌曲', dupFraction);
    _drawLabel(
        canvas,
        size,
        center,
        ringOuter,
        -math.pi / 2 +
            dupFraction * 2 * math.pi +
            (1 - dupFraction) * math.pi,
        '其他歌曲',
        1 - dupFraction);
  }

  void _drawLabel(Canvas canvas, Size size, Offset center, double outerR,
      double midAngle, String label, double fraction) {
    if (fraction <= 0) return;
    final cosA = math.cos(midAngle);
    final sinA = math.sin(midAngle);
    final edge = Offset(
        center.dx + outerR * cosA, center.dy + outerR * sinA);
    final elbowR = outerR + 14;
    final elbow = Offset(
        center.dx + elbowR * cosA, center.dy + elbowR * sinA);
    final toRight = cosA >= 0;
    final end = Offset(elbow.dx + (toRight ? 12 : -12), elbow.dy);
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    canvas.drawLine(edge, elbow, linePaint);
    canvas.drawLine(elbow, end, linePaint);
    final tp = TextPainter(
      text: TextSpan(
        text: '${(fraction * 100).toStringAsFixed(1)}%\n$label',
        style: labelStyle,
      ),
      textDirection: TextDirection.ltr,
      textAlign: toRight ? TextAlign.left : TextAlign.right,
    );
    tp.layout();
    // 文字贴在线端内侧，夹在画布内不越界。
    var dx = toRight ? end.dx + 4 : end.dx - 4 - tp.width;
    dx = dx.clamp(0.0, size.width - tp.width);
    var dy = (end.dy - tp.height / 2).clamp(0.0, size.height - tp.height);
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.dupFraction != dupFraction ||
      old.dupColor != dupColor ||
      old.otherColor != otherColor ||
      old.labelStyle != labelStyle ||
      old.lineColor != lineColor;
}

/// 图例点：色点 + 名称（圆环图下方居中一行）。
class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
