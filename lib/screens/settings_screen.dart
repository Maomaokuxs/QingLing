import '../models/duplicate_group.dart';
import '../services/app_version.dart';
import '../services/cache_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import 'about_screen.dart';
import 'dir_stats_screen.dart';
import 'export_lists_screen.dart';
import 'lrc_dedup_screen.dart';
import '../widgets/minimal_ui.dart';
import '../services/ignore_service.dart';

class SettingsScreen extends StatelessWidget {
  /// 目录统计 / 导出清单改为独立页面：主屏传当前分组，
  /// 设置页直接 push 进去，返回回到设置页，不再 pop 回主页。
  final List<DuplicateGroup>? dirGroups;
  final int? totalBytes;

  const SettingsScreen({super.key, this.dirGroups, this.totalBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
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
                    '设置',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 5,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  _SectionHeader(title: '扫描设置'),
                  ValueListenableBuilder<bool>(
                    valueListenable: autoScanNotifier,
                    builder: (context, autoOn, _) => _MinimalCard(
                      children: [
                        _scanDirRow(context),
                        _keepBestRow(),
                        _keepRuleRow(context),
                        _ignoredRow(context),
                        _autoScanRow(autoOn),
                        if (autoOn) _autoScanDaysRow(),
                      ],
                    ),
                  ),
                  _SectionHeader(title: '识别设置'),
                  _MinimalCard(
                    children: [
                      _fingerprintRow(),
                      _crossLingualRow(),
                      _shortSongsRow(),
                      _spectralRow(),
                    ],
                  ),
                  _SectionHeader(title: '回收站'),
                  _MinimalCard(children: [_trashRetentionRow()]),
                  _SectionHeader(title: '缓存'),
                  _MinimalCard(children: [const _CacheTile()]),
                  _SectionHeader(title: '工具'),
                  _MinimalCard(
                    children: [
                      _Row(
                        title: '导出清单',
                        subtitle: '导出当前重复清单并分享，历史清单记录也在里面，可从回收站恢复',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ExportListsScreen(
                              groups: dirGroups ?? const [],
                            ),
                          ),
                        ),
                      ),
                      _Row(
                        title: '目录统计',
                        subtitle: '按目录查看重复文件的分布与占用空间',
                        onTap: dirGroups == null
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      DirStatsScreen(
                                        groups: dirGroups!,
                                        totalBytes: totalBytes,
                                      ),
                                ),
                              ),
                      ),
                      _Row(
                        title: '歌词去重',
                        subtitle: '扫描并清理重复的歌词文件',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LrcDedupScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  _SectionHeader(title: '外观'),
                  _MinimalCard(children: [_themeModeRow()]),
                  _SectionHeader(title: '关于'),
                  _MinimalCard(
                    children: [
                      _updateCheckRow(),
                      FutureBuilder<String>(
                        future: AppVersion.get(),
                        builder: (context, snap) => _Row(
                          title: '关于',
                          subtitle: '版本 ${snap.data ?? '…'} · 检查更新 · 开源许可',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AboutScreen(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 扫描范围
  Widget _scanDirRow(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: scanAllDirsNotifier,
      builder: (context, all, _) => ValueListenableBuilder<List<String>>(
        valueListenable: scanDirsNotifier,
        builder: (context, dirs, _) => _Row(
          title: '扫描范围',
          subtitle: all
              ? '全部目录'
              : (dirs.isEmpty ? '未勾选任何目录' : '仅扫描：${dirs.join('、')}'),
          trailing: _MinimalTextAction(
            label: '设置',
            onTap: () => _showScanDirDialog(context),
          ),
          onTap: () => _showScanDirDialog(context),
        ),
      ),
    );
  }

  /// 每组保留最佳：1/2/3
  Widget _keepBestRow() {
    return ValueListenableBuilder<int>(
      valueListenable: keepBestNotifier,
      builder: (context, keepN, _) => _Row(
        title: '每组保留最佳',
        subtitle: '自动勾选时，每组保留 $keepN 个音质最好的版本',
        trailing: MinimalSegmented<int>(
          options: const {1: '1', 2: '2', 3: '3'},
          value: keepN,
          onChanged: (v) => keepBestNotifier.value = v,
        ),
      ),
    );
  }

  /// 保留规则下拉
  Widget _keepRuleRow(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: keepRuleNotifier,
      builder: (context, rule, _) => ValueListenableBuilder<String>(
        valueListenable: keepDirNotifier,
        builder: (context, dir, _) => _Row(
          title: '保留规则',
          subtitle: rule == 'quality'
              ? '按音质分保留最好的版本'
              : rule == 'lossless'
              ? '优先保留无损格式（FLAC/WAV），再按音质'
              : (dir.isEmpty ? '优先保留指定目录（未设置目录）' : '优先保留目录：$dir'),
          trailing: _M3Dropdown<String>(
            value: rule,
            options: const {
              'quality': '音质优先',
              'lossless': '优先无损',
              'dir': '优先目录',
            },
            onChanged: (r) async {
              keepRuleNotifier.value = r;
              if (r == 'dir') {
                final d = await FilePicker.platform.getDirectoryPath();
                if (d != null) keepDirNotifier.value = d;
              }
            },
          ),
          onTap: rule == 'dir'
              ? () async {
                  final d = await FilePicker.platform.getDirectoryPath();
                  if (d != null) keepDirNotifier.value = d;
                }
              : null,
        ),
      ),
    );
  }

  /// 忽略的分组
  Widget _ignoredRow(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: IgnoreService.ignored,
      builder: (context, ignored, _) => _Row(
        title: '忽略的分组',
        subtitle: ignored.isEmpty
            ? '无，被忽略的分组不再出现在扫描结果中'
            : '${ignored.length} 组被忽略，不再出现在扫描结果中',
        trailing: _MinimalTextAction(
          label: '清空',
          enabled: ignored.isNotEmpty,
          onTap: () => _confirmClearIgnored(context),
        ),
      ),
    );
  }

  /// 自动扫描开关
  Widget _autoScanRow(bool enabled) {
    return ValueListenableBuilder<int>(
      valueListenable: autoScanDaysNotifier,
      builder: (context, days, _) => _Row(
        title: '自动扫描',
        subtitle: enabled ? '已开启：启动时若超过 $days 天未扫描则自动扫描' : '已关闭：仅手动扫描',
        trailing: MinimalSwitch(
          value: enabled,
          onChanged: (v) => autoScanNotifier.value = v,
        ),
      ),
    );
  }

  /// 扫描间隔（仅自动扫描开启时显示）
  Widget _autoScanDaysRow() {
    return ValueListenableBuilder<int>(
      valueListenable: autoScanDaysNotifier,
      builder: (context, days, _) => _Row(
        title: '扫描间隔',
        trailing: MinimalSegmented<int>(
          options: const {7: '7天', 14: '14天', 30: '30天'},
          value: days,
          onChanged: (v) => autoScanDaysNotifier.value = v,
        ),
      ),
    );
  }

  /// 文件指纹开关
  Widget _fingerprintRow() {
    return ValueListenableBuilder<bool>(
      valueListenable: fingerprintEnabledNotifier,
      builder: (context, enabled, _) => _Row(
        title: '文件指纹匹配',
        subtitle: enabled ? '已开启：识别文件名不同但内容相同的副本，扫描稍慢' : '已关闭：跳过文件内容比对，扫描更快',
        trailing: MinimalSwitch(
          value: enabled,
          onChanged: (v) => fingerprintEnabledNotifier.value = v,
        ),
      ),
    );
  }

  /// 组内版本细分开关
  Widget _crossLingualRow() {
    return ValueListenableBuilder<bool>(
      valueListenable: crossLingualEnabledNotifier,
      builder: (context, enabled, _) => _Row(
        title: '组内版本细分',
        subtitle: enabled
            ? '已开启：同名组内用声学指纹区分不同版本/语言，不自动勾选，扫描明显变慢'
            : '已关闭：跳过组内声学比对，扫描更快',
        trailing: MinimalSwitch(
          value: enabled,
          onChanged: (v) => crossLingualEnabledNotifier.value = v,
        ),
      ),
    );
  }

  /// 扫描短音频开关：短于 30 秒的音频（游戏 BGM、片段等）是否进扫描
  Widget _shortSongsRow() {
    return ValueListenableBuilder<bool>(
      valueListenable: includeShortSongsNotifier,
      builder: (context, enabled, _) => _Row(
        title: '扫描 30 秒以下短音频',
        subtitle: enabled
            ? '已开启：30 秒以下的短音频也进扫描（如游戏 BGM、片段）'
            : '已关闭：短于 30 秒的音频不扫描',
        trailing: MinimalSwitch(
          value: enabled,
          onChanged: (v) => includeShortSongsNotifier.value = v,
        ),
      ),
    );
  }

  /// 假无损检测开关：默认关闭。打开后对组内无损文件做频谱分析，
  /// 截止明显低于奈奎斯特的判疑似假无损，扫描变慢（首扫组内文件多算）。
  Widget _spectralRow() {
    return ValueListenableBuilder<bool>(
      valueListenable: spectralEnabledNotifier,
      builder: (context, enabled, _) => _Row(
        title: '假无损检测',
        subtitle: enabled
            ? '已开启：组内无损文件做频谱分析，疑似假无损降级、不优先保留，扫描变慢'
            : '已关闭：跳过频谱分析，无损文件按标称音质排序',
        trailing: MinimalSwitch(
          value: enabled,
          onChanged: (v) => spectralEnabledNotifier.value = v,
        ),
      ),
    );
  }

  /// 启动时检查更新开关：默认开启。打开后每次启动自动查一次 GitHub 最新
  /// release，有新版弹更新提示；关闭则启动时不检查、不提示，仍可在关于页手动查。
  Widget _updateCheckRow() {
    return ValueListenableBuilder<bool>(
      valueListenable: updateCheckOnStartupNotifier,
      builder: (context, enabled, _) => _Row(
        title: '启动时检查更新',
        subtitle: enabled
            ? '已开启：启动时自动查新版，有新版弹更新提示'
            : '已关闭：启动时不检查更新，可在关于页手动检查',
        trailing: MinimalSwitch(
          value: enabled,
          onChanged: (v) => updateCheckOnStartupNotifier.value = v,
        ),
      ),
    );
  }

  /// 回收站自动清理
  Widget _trashRetentionRow() {
    return ValueListenableBuilder<int>(
      valueListenable: trashRetentionDaysNotifier,
      builder: (context, days, _) => _Row(
        title: '回收站自动清理',
        subtitle: days == 0 ? '永不自动清理，手动清空回收站' : '超过 $days 天的回收站记录自动删除',
        trailing: _M3Dropdown<int>(
          value: days,
          options: const {0: '永不', 7: '7天', 14: '14天', 30: '30天'},
          onChanged: (v) => trashRetentionDaysNotifier.value = v,
        ),
      ),
    );
  }

  /// 昼夜模式：下拉选择（跟随系统/浅色/深色）
  Widget _themeModeRow() {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => _Row(
        title: '昼夜模式',
        subtitle: '跟随系统 / 浅色 / 深色',
        trailing: _M3Dropdown<ThemeMode>(
          value: mode,
          options: const {
            ThemeMode.system: '跟随系统',
            ThemeMode.light: '浅色',
            ThemeMode.dark: '深色',
          },
          onChanged: (v) => themeModeNotifier.value = v,
        ),
      ),
    );
  }
}

/// 极简设置行：标题 + 副标题 + 右侧控件，无前置图标。
class _Row extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({required this.title, this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ] else if (onTap != null)
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.outline,
                size: 18,
              ),
          ],
        ),
      ),
    );
  }
}

/// 极简文字操作：小字按钮，用于"设置/清空"等行内操作。
class _MinimalTextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  const _MinimalTextAction({
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: secondaryFillColor(context),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 极简分组卡片：扁平白卡，1px 细边框，16px 圆角，行间细分隔线。
class _MinimalCard extends StatelessWidget {
  final List<Widget> children;

  const _MinimalCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final divided = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        divided.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 14,
            endIndent: 14,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        );
      }
      divided.add(children[i]);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: divided),
    );
  }
}

/// 设置页分组标题：眉题样式（小字/600/字间距/灰字）
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 与极简风统一的下拉框：透明底 + 1px 细边框。
/// 点击弹出自定义极简菜单：白卡 + 1px 细边框 + 14px 圆角，
/// 选中项黑字加粗 + 右侧对勾，无灰底高亮。
class _M3Dropdown<T> extends StatelessWidget {
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  const _M3Dropdown({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  Future<void> _showMenu(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final entries = options.entries.toList();
    final result = await showMenu<T>(
      context: context,
      position: position,
      color: scheme.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant, width: 1),
      ),
      items: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const PopupMenuDivider(height: 1),
          PopupMenuItem<T>(
            value: entries[i].key,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entries[i].value,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: entries[i].key == value
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: entries[i].key == value
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (entries[i].key == value) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_rounded, size: 14, color: scheme.onSurface),
                ],
              ],
            ),
          ),
        ],
      ],
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _showMenu(context),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant, width: 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              options[value] ?? '',
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 缓存行：显示扫描缓存大小，一键清除（含确认框）
class _CacheTile extends StatefulWidget {
  const _CacheTile();

  @override
  State<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends State<_CacheTile> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final b = await CacheService.sizeBytes();
    if (mounted) setState(() => _bytes = b);
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清除扫描缓存？'),
        content: const Text(
          '将删除扫描结果、文件指纹、声学指纹、封面/歌词四项缓存。'
          '下次扫描会重新计算、慢一些，但扫描结果不受影响。'
          '回收站和各项设置不会被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final freed = await CacheService.clearAll();
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已清除扫描缓存，释放 ${_fmt(freed)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    return _Row(
      title: '清除扫描缓存',
      subtitle: b == null ? '正在统计…' : '当前缓存 ${_fmt(b)}，清除后下次扫描变慢，结果不受影响',
      trailing: _MinimalTextAction(
        label: '清除',
        enabled: b != null && b > 0,
        onTap: _confirmClear,
      ),
    );
  }
}

Future<void> _confirmClearIgnored(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('恢复被忽略的分组'),
      content: const Text('清空后，这些分组在下次扫描时会重新出现。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await IgnoreService.clear();
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已清空，请重新扫描')));
    }
  }
}

/// 扫描范围：顶部"全部目录"总开关 + 目录清单。
/// 勾上就是扫，不勾就是不扫；可通过系统文件夹选择器添加预设之外的目录。
Future<void> _showScanDirDialog(BuildContext context) async {
  final presets = [
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Documents',
  ];
  var scanAll = scanAllDirsNotifier.value;
  final selected = <String>{}..addAll(scanDirsNotifier.value);

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx2, setState) => AlertDialog(
        title: const Text('扫描范围'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                title: const Text('全部目录', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '关闭后仅扫描下方勾选的目录',
                  style: TextStyle(fontSize: 11),
                ),
                value: scanAll,
                onChanged: (v) => setState(() => scanAll = v ?? true),
              ),
              const Divider(height: 8),
              for (final p in presets)
                CheckboxListTile(
                  title: Text(
                    p.split('/').last.isEmpty ? p : p.split('/').last,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(p, style: const TextStyle(fontSize: 10)),
                  value: selected.contains(p),
                  onChanged: scanAll
                      ? null
                      : (v) {
                          setState(() {
                            if (v == true) {
                              selected.add(p);
                            } else {
                              selected.remove(p);
                            }
                          });
                        },
                ),
              for (final p
                  in selected.where((e) => !presets.contains(e)).toList())
                CheckboxListTile(
                  title: Text(
                    p.split('/').last.isEmpty ? p : p.split('/').last,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(p, style: const TextStyle(fontSize: 10)),
                  value: true,
                  onChanged: scanAll
                      ? null
                      : (_) => setState(() => selected.remove(p)),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: scanAll
                      ? null
                      : () async {
                          final dir = await FilePicker.platform
                              .getDirectoryPath();
                          if (dir != null && dir.isNotEmpty) {
                            setState(() => selected.add(dir));
                          }
                        },
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('添加目录…', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              scanAllDirsNotifier.value = scanAll;
              scanDirsNotifier.value = scanAll ? [] : selected.toList();
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
