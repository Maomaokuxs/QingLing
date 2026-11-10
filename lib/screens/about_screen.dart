import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_version.dart';
import '../services/update_service.dart';
import '../widgets/minimal_ui.dart';

/// 关于页：应用图标（真实应用图标 asset）+ 版本 + 简介 + 三行入口。
/// 图标必须用 assets/app_icon.png（即 android mipmap-xxxhdpi 的粗波浪图），
/// 不手画 SVG，保证跟桌面图标完全一致。
/// 版本号运行时读包信息（AppVersion），与 pubspec.yaml 同步，不手写。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    AppVersion.get().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  /// 检查更新：查 GitHub 最新 release，与当前版本比对。
  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await UpdateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _checking = false);
    switch (result.status) {
      case UpdateStatus.upToDate:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已是最新版本')));
      case UpdateStatus.noReleases:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂无可用更新')));
      case UpdateStatus.error:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检查失败：${result.message}')));
      case UpdateStatus.available:
        _showUpdateDialog(result.info!);
    }
  }

  /// 新版弹窗：版本号 + 更新说明 + 下载安装。
  Future<void> _showUpdateDialog(UpdateInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('发现新版本 ${info.version}'),
        content: SingleChildScrollView(
          child: Text(
            info.notes.isEmpty ? '本次更新没有附带说明。' : info.notes,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('下载更新'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _downloadAndInstall(info);
  }

  /// 下载 APK（带进度弹窗）后调系统安装器。
  /// 下载完成自动关弹窗；点取消会中断下载。
  Future<void> _downloadAndInstall(UpdateInfo info) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    final progressNotifier = ValueNotifier<double>(0);
    final totalKnown = info.apkSizeBytes > 0;
    var dialogOpen = false;

    final downloadFuture = UpdateService.downloadApk(info.apkUrl, (
      received,
      total,
    ) {
      if (total > 0) progressNotifier.value = received / total;
    }, client: client).then<String?>((path) => path).catchError((_) => null);

    final path = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        dialogOpen = true;
        // 下载完成（成功或失败）即关掉本弹窗，带回结果
        downloadFuture.then((p) {
          if (dialogOpen) {
            dialogOpen = false;
            Navigator.pop(c, p);
          }
        });
        return AlertDialog(
          title: Text('正在下载 ${info.version}'),
          content: ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (c2, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: totalKnown ? p : null),
                const SizedBox(height: 8),
                Text(
                  totalKnown ? '已下载 ${(p * 100).toStringAsFixed(0)}%' : '正在下载…',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                dialogOpen = false;
                client.close(force: true);
                Navigator.pop(c, null);
              },
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
    progressNotifier.dispose();
    client.close();
    if (path == null || !mounted) return;
    final installed = await UpdateService.installApk(path);
    if (!mounted) return;
    if (!installed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法调起安装，请检查存储权限')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 关于
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
                    '关于',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  // 应用图标 + 名称 + 版本 + 简介
                  const SizedBox(height: 28),
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.asset(
                        'assets/app_icon.png',
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Center(
                    child: Text(
                      '清聆',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      _version.isEmpty ? '版本 …' : '版本 $_version',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      '相似歌曲识别与低音质清理，帮你找出重复歌曲，释放存储空间。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.7,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  // 三行入口卡片
                  _AboutCard(
                    children: [
                      _AboutRow(
                        title: '检查更新',
                        trailing: _checking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap: _checkUpdate,
                      ),
                      _AboutRow(
                        title: '开源许可',
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: '清聆',
                          applicationVersion: _version,
                          applicationIcon: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset(
                              'assets/app_icon.png',
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                      _AboutRow(
                        title: '问题反馈',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('请通过 GitHub Issues 反馈'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      '清聆 · 让音乐库更干净',
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 关于页入口卡片：扁平白卡，1px 细边框，16px 圆角，行间细分隔线。
class _AboutCard extends StatelessWidget {
  final List<Widget> children;

  const _AboutCard({required this.children});

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

/// 关于页入口行：14px 加粗黑字 + 右箭头（或指定的 trailing）。
class _AboutRow extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  final Widget? trailing;

  const _AboutRow({required this.title, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            trailing ??
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
