import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';

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
          const Divider(height: 1),
          ValueListenableBuilder<List<String>>(
            valueListenable: scanDirsNotifier,
            builder: (context, dirs, _) => ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('扫描目录'),
              subtitle: Text(
                dirs.isEmpty ? '全部目录' : dirs.join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              trailing: TextButton(
                onPressed: () => _showScanDirDialog(context),
                child: const Text('选择'),
              ),
              onTap: () => _showScanDirDialog(context),
            ),
          ),
          const Divider(height: 1),
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
          const Divider(height: 1),
        ],
      ),
    );
  }
}

Future<void> _showScanDirDialog(BuildContext context) async {
  final presets = [
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Documents',
  ];
  final current = List<String>.from(scanDirsNotifier.value);
  final customCtrl = TextEditingController(
    text: current.where((p) => !presets.contains(p)).join('; '),
  );
  bool isAll = current.isEmpty;
  final selected = <String>{}..addAll(current);

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx2, setState) => AlertDialog(
        title: const Text('选择扫描目录'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                title: const Text('全部目录', style: TextStyle(fontSize: 13)),
                value: isAll,
                onChanged: (v) {
                  setState(() {
                    isAll = v ?? true;
                    if (isAll) selected.clear();
                  });
                },
              ),
              const Divider(height: 8),
              for (final p in presets)
                CheckboxListTile(
                  title: Text(
                    p.split('/').last.isEmpty ? p : p.split('/').last,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(p, style: const TextStyle(fontSize: 10)),
                  value: !isAll && selected.contains(p),
                  onChanged: isAll
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
              const Divider(height: 12),
              TextField(
                controller: customCtrl,
                enabled: !isAll,
                decoration: const InputDecoration(
                  labelText: '自定义路径（; 分隔）',
                  hintText: '/storage/emulated/0/MyMusic',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: !isAll
                    ? () async {
                        final dir = await FilePicker.platform.getDirectoryPath(
                          dialogTitle: '选择扫描目录',
                        );
                        if (dir != null) {
                          setState(() {
                            selected.add(dir);
                            final customs = selected
                                .where((p) => !presets.contains(p))
                                .toList();
                            customCtrl.text = customs.join('; ');
                          });
                        }
                      }
                    : null,
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label:
                    const Text('系统文件夹选择', style: TextStyle(fontSize: 12)),
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
              if (isAll) {
                scanDirsNotifier.value = [];
              } else {
                final custom = customCtrl.text
                    .split(';')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                scanDirsNotifier.value = {...selected, ...custom}.toList();
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
