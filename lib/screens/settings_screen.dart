import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/ignore_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        children: [
          _SectionHeader(title: '扫描设置'),
          ValueListenableBuilder<bool>(
                      valueListenable: scanAllDirsNotifier,
                      builder: (context, all, _) =>
                          ValueListenableBuilder<List<String>>(
                        valueListenable: scanDirsNotifier,
                        builder: (context, dirs, _) => ListTile(
                          leading: const Icon(Icons.folder_open_rounded),
                          title: const Text('扫描范围'),
                          subtitle: Text(
                            all
                                ? '全部目录'
                                : (dirs.isEmpty
                                    ? '未勾选任何目录'
                                    : '仅扫描：${dirs.join('、')}'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          trailing: TextButton(
                            onPressed: () => _showScanDirDialog(context),
                            child: const Text('设置'),
                          ),
                          onTap: () => _showScanDirDialog(context),
                        ),
                      ),
                    ),
          ValueListenableBuilder<int>(
                      valueListenable: keepBestNotifier,
                      builder: (context, keepN, _) => ListTile(
                        leading: const Icon(Icons.playlist_add_check_rounded),
                        title: const Text('每组保留最佳'),
                        subtitle: Text(
                          '自动勾选时，每组保留 $keepN 个音质最好的版本',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        trailing: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                              value: 1,
                              label: Text('1', style: TextStyle(fontSize: 12)),
                            ),
                            ButtonSegment(
                              value: 2,
                              label: Text('2', style: TextStyle(fontSize: 12)),
                            ),
                            ButtonSegment(
                              value: 3,
                              label: Text('3', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                          selected: {keepN},
                          onSelectionChanged: (s) => keepBestNotifier.value = s.first,
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ),
          ValueListenableBuilder<String>(
                      valueListenable: keepRuleNotifier,
                      builder: (context, rule, _) =>
                          ValueListenableBuilder<String>(
                        valueListenable: keepDirNotifier,
                        builder: (context, dir, _) => ListTile(
                          leading: const Icon(Icons.rule_rounded),
                          title: const Text('保留规则'),
                          subtitle: Text(
                            rule == 'quality'
                                ? '按音质分保留最好的版本'
                                : rule == 'lossless'
                                    ? '优先保留无损格式（FLAC/WAV），再按音质'
                                    : (dir.isEmpty
                                        ? '优先保留指定目录（未设置目录）'
                                        : '优先保留目录：$dir'),
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          trailing: SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                value: 'quality',
                                label:
                                    Text('音质优先', style: TextStyle(fontSize: 12)),
                              ),
                              ButtonSegment(
                                value: 'lossless',
                                label:
                                    Text('优先无损', style: TextStyle(fontSize: 12)),
                              ),
                              ButtonSegment(
                                value: 'dir',
                                label:
                                    Text('优先目录', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                            selected: {rule},
                            onSelectionChanged: (sel) async {
                              final r = sel.first;
                              keepRuleNotifier.value = r;
                              if (r == 'dir') {
                                final d = await FilePicker.platform
                                    .getDirectoryPath();
                                if (d != null) keepDirNotifier.value = d;
                              }
                            },
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          onTap: rule == 'dir'
                              ? () async {
                                  final d = await FilePicker.platform
                                      .getDirectoryPath();
                                  if (d != null) keepDirNotifier.value = d;
                                }
                              : null,
                        ),
                      ),
                    ),
          ValueListenableBuilder<Set<String>>(
                      valueListenable: IgnoreService.ignored,
                      builder: (context, ignored, _) => ListTile(
                        leading: const Icon(Icons.visibility_off_rounded),
                        title: const Text('忽略的分组'),
                        subtitle: Text(
                          ignored.isEmpty
                              ? '无，被忽略的分组不再出现在扫描结果中'
                              : '${ignored.length} 组被忽略，不再出现在扫描结果中',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        trailing: TextButton(
                          onPressed: ignored.isEmpty
                              ? null
                              : () => _confirmClearIgnored(context),
                          child: const Text('清空'),
                        ),
                      ),
                    ),
          ValueListenableBuilder<bool>(
                      valueListenable: autoScanNotifier,
                      builder: (context, enabled, _) =>
                          ValueListenableBuilder<int>(
                        valueListenable: autoScanDaysNotifier,
                        builder: (context, days, _) => SwitchListTile(
                          secondary: const Icon(Icons.schedule_rounded),
                          title: const Text('自动扫描'),
                          subtitle: Text(
                            enabled
                                ? '已开启：启动时若超过 $days 天未扫描则自动扫描'
                                : '已关闭：仅手动扫描',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          value: enabled,
                          onChanged: (v) =>
                              autoScanNotifier.value = v,
                        ),
                      ),
                    ),
          ValueListenableBuilder<bool>(
                      valueListenable: autoScanNotifier,
                      builder: (context, enabled, _) {
                        if (!enabled) return const SizedBox.shrink();
                        return ValueListenableBuilder<int>(
                          valueListenable: autoScanDaysNotifier,
                          builder: (context, days, _) => ListTile(
                            leading: const Icon(Icons.timelapse_rounded),
                            title: const Text('扫描间隔'),
                            trailing: SegmentedButton<int>(
                              segments: const [
                                ButtonSegment(
                                  value: 7,
                                  label: Text('7天',
                                      style: TextStyle(fontSize: 12)),
                                ),
                                ButtonSegment(
                                  value: 14,
                                  label: Text('14天',
                                      style: TextStyle(fontSize: 12)),
                                ),
                                ButtonSegment(
                                  value: 30,
                                  label: Text('30天',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ],
                              selected: {days},
                              onSelectionChanged: (sel) =>
                                  autoScanDaysNotifier.value =
                                      sel.first,
                              showSelectedIcon: false,
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
          _SectionHeader(title: '识别设置'),
          ValueListenableBuilder<bool>(
                      valueListenable: fingerprintEnabledNotifier,
                      builder: (context, enabled, _) => SwitchListTile(
                        title: const Text('文件指纹匹配'),
                        subtitle: Text(
                          enabled
                              ? '已开启：识别文件名不同但内容相同的副本，扫描稍慢'
                              : '已关闭：跳过文件内容比对，扫描更快',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        value: enabled,
                        onChanged: (v) => fingerprintEnabledNotifier.value = v,
                        secondary: const Icon(Icons.fingerprint_rounded),
                      ),
                    ),
          ValueListenableBuilder<bool>(
                      valueListenable: acousticFpEnabledNotifier,
                      builder: (context, enabled, _) => SwitchListTile(
                        title: const Text('音频指纹识别'),
                        subtitle: Text(
                          enabled
                              ? '已开启：标题完全不同的同音频副本也能认出，扫描稍慢'
                              : '已关闭：跳过声音内容比对，扫描更快',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        value: enabled,
                        onChanged: (v) => acousticFpEnabledNotifier.value = v,
                        secondary: const Icon(Icons.audio_file_rounded),
                      ),
                    ),
          ValueListenableBuilder<bool>(
                      valueListenable: batchSpectrumNotifier,
                      builder: (context, enabled, _) => SwitchListTile(
                        title: const Text('批量检测假无损'),
                        subtitle: Text(
                          enabled
                              ? '已开启：扫描后后台检测无损文件，结果页标记疑似假无损'
                              : '已关闭：只在文件详情里手动检测',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        value: enabled,
                        onChanged: (v) => batchSpectrumNotifier.value = v,
                        secondary: const Icon(Icons.graphic_eq_rounded),
                      ),
                    ),
          _SectionHeader(title: '回收站'),
          ValueListenableBuilder<int>(
                      valueListenable: trashRetentionDaysNotifier,
                      builder: (context, days, _) => ListTile(
                        leading: const Icon(Icons.auto_delete_rounded),
                        title: const Text('回收站自动清理'),
                        subtitle: Text(
                          days == 0
                              ? '永不自动清理，手动清空回收站'
                              : '超过 $days 天的回收站记录自动删除',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        trailing: DropdownButton<int>(
                          value: days,
                          underline: const SizedBox.shrink(),
                          style: const TextStyle(fontSize: 13),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('永不')),
                            DropdownMenuItem(value: 7, child: Text('7天')),
                            DropdownMenuItem(value: 14, child: Text('14天')),
                            DropdownMenuItem(value: 30, child: Text('30天')),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              trashRetentionDaysNotifier.value = v;
                            }
                          },
                        ),
                      ),
                    ),
          _SectionHeader(title: '外观'),
          ValueListenableBuilder<ThemeMode>(
                      valueListenable: themeModeNotifier,
                      builder: (context, mode, _) => ListTile(
                        leading: Icon(switch (mode) {
                          ThemeMode.light => Icons.light_mode_rounded,
                          ThemeMode.dark => Icons.dark_mode_rounded,
                          ThemeMode.system => Icons.brightness_auto_rounded,
                        }),
                        title: const Text('昼夜模式'),
                        trailing: SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: Text('自动', style: TextStyle(fontSize: 12)),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('浅色', style: TextStyle(fontSize: 12)),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('深色', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                          selected: {mode},
                          onSelectionChanged: (s) => themeModeNotifier.value = s.first,
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ),
                ],
      ),
    );
  }
}


/// 设置页分组标题
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
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: scheme.primary,
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清空，请重新扫描')),
      );
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
              for (final p in selected.where((e) => !presets.contains(e)).toList())
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
                          final dir =
                              await FilePicker.platform.getDirectoryPath();
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
              scanDirsNotifier.value =
                  scanAll ? [] : selected.toList();
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
