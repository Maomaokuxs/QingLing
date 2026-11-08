import 'package:flutter/material.dart';

/// 清聆极简风共用组件：全扁平，无渐变、无阴影、无内高光。
/// 所有颜色都取自 Theme，自动适配深色模式。
/// 深色模式遵循浅色的舒适对比度：主色压暗（避免纯白晃眼），次级提亮（保证可见）。

/// 主强调填充色：浅色下近黑 #161616；深色下用 72% 不透明度的 onSurface，
/// 得到柔和浅灰，避免纯白在黑底上的光晕效应。
Color primaryFillColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? scheme.onSurface.withValues(alpha: 0.72)
      : const Color(0xFF161616);
}

/// 主强调填充上的图标/文字色：浅色下纯白，深色下用 surface（深色）保证对比。
Color onPrimaryFillColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? scheme.surface : Colors.white;
}

/// 次级按钮底色：浅色下 surfaceContainerHighest；深色下同样，
/// 但调用处需加 outlineVariant 描边以在黑底上区分。
Color secondaryFillColor(BuildContext context) {
  return Theme.of(context).colorScheme.surfaceContainerHighest;
}

/// 筛选 chip：浅灰底 pill，选中态为反色。
/// 深色下选中为柔和浅灰（不晃眼），未选中加描边保证可见。
class MinimalChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  const MinimalChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? primaryFillColor(context)
              : secondaryFillColor(context),
          borderRadius: BorderRadius.circular(999),
          border: !selected && dark
              ? Border.all(color: scheme.outlineVariant, width: 1)
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected
                ? onPrimaryFillColor(context)
                : scheme.onSurfaceVariant,
          ),
        ),
        ),
      ),
    );
  }
}

/// 扁平圆形图标按钮：无渐变无阴影。
/// dark=true 时为重色底（浅色下近黑，深色下柔和浅灰），图标反色；
/// dark=false 时为浅灰底 + 深色图标，深色下加描边。
class MinimalIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool dark;
  final double size;
  final double iconSize;
  final String? tooltip;

  const MinimalIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.dark = false,
    this.size = 44,
    this.iconSize = 20,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final btn = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: dark ? primaryFillColor(context) : secondaryFillColor(context),
        shape: CircleBorder(
          side: !dark && isDark
              ? BorderSide(color: scheme.outlineVariant, width: 1)
              : BorderSide.none,
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Icon(
            icon,
            size: iconSize,
            color: dark
                ? onPrimaryFillColor(context)
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}

/// 扁平圆形复选框：未选中透明底灰圈，选中为重色底 + 反色对勾。
/// 深色下选中为柔和浅灰，不晃眼。
class MinimalCheckbox extends StatelessWidget {
  final bool checked;
  final VoidCallback onTap;
  final double size;

  const MinimalCheckbox({
    super.key,
    required this.checked,
    required this.onTap,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked ? primaryFillColor(context) : Colors.transparent,
          border: Border.all(
            color: checked ? primaryFillColor(context) : scheme.outline,
            width: 1.5,
          ),
        ),
        child: checked
            ? Icon(Icons.check_rounded,
                size: size * 0.6, color: onPrimaryFillColor(context))
            : null,
      ),
    );
  }
}


/// 自定义黑白开关：开=重色底（浅色近黑/深色柔和浅灰），关=灰底。替代 M3 Switch（紫色）。
class MinimalSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const MinimalSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 46,
        height: 27,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: value
              ? primaryFillColor(context)
              : scheme.surfaceContainerHighest,
          border: !value && dark
              ? Border.all(color: scheme.outlineVariant, width: 1)
              : null,
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              top: 3.5,
              left: value ? 22.5 : 3.5,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? onPrimaryFillColor(context) : Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 极简分段选择：一排小 chip，选中为重色。替代 M3 SegmentedButton（紫色）。
class MinimalSegmented<T> extends StatelessWidget {
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  const MinimalSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final e in options.entries)
          MinimalChip(
            label: e.value,
            selected: e.key == value,
            onTap: () => onChanged(e.key),
          ),
      ],
    );
  }
}

/// 音质文字颜色：无损绿 / 高音质蓝 / 标准灰 / 较差红，纯文字不做徽章。
/// 深色模式用提亮配色保证对比度。
Color qualityTextColor(BuildContext context, String label) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (label) {
    '无损' => dark ? const Color(0xFF4CC38A) : const Color(0xFF0E7A5F),
    '高音质' => dark ? const Color(0xFF8AB4F8) : const Color(0xFF2B5CB8),
    '标准' => scheme.onSurfaceVariant,
    _ => dark ? const Color(0xFFF28B82) : const Color(0xFFC5221F),
  };
}
