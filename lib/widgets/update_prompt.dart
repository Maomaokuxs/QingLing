import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// 新版提示弹窗：版本号 + 更新说明，点「下载更新」后下载 APK 并调系统安装器。
/// 供关于页手动检查与启动自动检查共用。
Future<void> showUpdatePrompt(BuildContext context, UpdateInfo info) async {
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
  if (ok != true || !context.mounted) return;
  await downloadAndInstallUpdate(context, info);
}

/// 下载 APK（带进度弹窗）后调系统安装器。
/// 下载完成自动关弹窗；点取消会中断下载。
Future<void> downloadAndInstallUpdate(
  BuildContext context,
  UpdateInfo info,
) async {
  final progressNotifier = ValueNotifier<double>(0);
  final totalKnown = info.apkSizeBytes > 0;
  var dialogOpen = false;

  final downloadFuture = UpdateService.downloadApk(info.apkUrl, (
    received,
    total,
  ) {
    if (total > 0) progressNotifier.value = received / total;
  }).then<String?>((path) => path).catchError((_) => null);

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
              UpdateService.cancelDownload();
              Navigator.pop(c, null);
            },
            child: const Text('取消'),
          ),
        ],
      );
    },
  );
  progressNotifier.dispose();
  if (path == null || !context.mounted) return;
  final installed = await UpdateService.installApk(path);
  if (!context.mounted) return;
  if (!installed) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法调起安装，请检查存储权限')));
  }
}
