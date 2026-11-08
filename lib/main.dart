import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/ignore_service.dart';
import 'services/trash_service.dart';

/// 全局主题模式：system 自动跟随系统，light/dark 手动切换
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);
/// 声纹开关（设置页可自由开启）
final ValueNotifier<bool> fingerprintEnabledNotifier = ValueNotifier(true);
/// 跨语言版本匹配开关：默认关闭（chroma 计算重，扫描慢），需要时手动开。
final ValueNotifier<bool> crossLingualEnabledNotifier = ValueNotifier(false);
/// 扫描范围：true=扫描全部目录（默认）；false=仅扫描 scanDirs 中的目录（前缀匹配）。
/// 清单语义：勾上就是扫，不勾就是不扫。
final ValueNotifier<bool> scanAllDirsNotifier = ValueNotifier(true);
final ValueNotifier<List<String>> scanDirsNotifier = ValueNotifier([]);
/// 每组保留的音质最佳版本数（1~3）
final ValueNotifier<int> keepBestNotifier = ValueNotifier(1);
/// 保留规则：quality=音质优先，lossless=优先无损，dir=优先指定目录
final ValueNotifier<String> keepRuleNotifier = ValueNotifier('quality');
/// 优先保留的目录（keepRule=dir 时生效）
final ValueNotifier<String> keepDirNotifier = ValueNotifier('');
/// 自动扫描：启动时若距离上次扫描超过 N 天则自动扫描
final ValueNotifier<bool> autoScanNotifier = ValueNotifier(false);
final ValueNotifier<int> autoScanDaysNotifier = ValueNotifier(7);
/// 回收站自动清理：超过 N 天的记录自动删除，0=永不
final ValueNotifier<int> trashRetentionDaysNotifier = ValueNotifier(30);

Future<void> _loadSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final fp = prefs.getBool('fingerprint_enabled');
  if (fp != null) fingerprintEnabledNotifier.value = fp;
  final cl = prefs.getBool('crosslingual_enabled');
  if (cl != null) crossLingualEnabledNotifier.value = cl;
  final tm = prefs.getString('theme_mode');
  if (tm != null) {
    themeModeNotifier.value = switch (tm) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }
  // 新 key 优先；没有则从老版本 key 迁移
  if (prefs.containsKey('scan_all_dirs')) {
    scanAllDirsNotifier.value = prefs.getBool('scan_all_dirs') ?? true;
    scanDirsNotifier.value = prefs.getStringList('scan_dirs') ?? [];
  } else if (prefs.containsKey('scan_scope_mode')) {
    // 三段式版本的迁移：exclude 无法表示，回退为全部（超集，最安全）
    final m = prefs.getString('scan_scope_mode');
    if (m == 'include') {
      scanAllDirsNotifier.value = false;
      scanDirsNotifier.value = prefs.getStringList('scan_scope_dirs') ?? [];
    } else {
      scanAllDirsNotifier.value = true;
    }
    await prefs.remove('scan_scope_mode');
    await prefs.remove('scan_scope_dirs');
  } else {
    final oldDirs = prefs.getStringList('scan_dirs') ?? [];
    if (oldDirs.isNotEmpty) {
      scanAllDirsNotifier.value = false;
      scanDirsNotifier.value = oldDirs;
    }
    await prefs.remove('scan_dirs');
    await prefs.remove('excluded_dirs');
  }
  final kb = prefs.getInt('keep_best');
  if (kb != null && kb >= 1 && kb <= 3) keepBestNotifier.value = kb;
  final kr = prefs.getString('keep_rule');
  if (kr == 'lossless' || kr == 'dir') keepRuleNotifier.value = kr!;
  keepDirNotifier.value = prefs.getString('keep_dir') ?? '';
  autoScanNotifier.value = prefs.getBool('auto_scan') ?? false;
  final asd = prefs.getInt('auto_scan_days');
  if (asd == 7 || asd == 14 || asd == 30) autoScanDaysNotifier.value = asd!;
  final tr = prefs.getInt('trash_retention_days');
  if (tr != null && tr >= 0) trashRetentionDaysNotifier.value = tr;
  fingerprintEnabledNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setBool('fingerprint_enabled', fingerprintEnabledNotifier.value));
  });
  crossLingualEnabledNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setBool('crosslingual_enabled', crossLingualEnabledNotifier.value));
  });
  themeModeNotifier.addListener(() {
    final v = switch (themeModeNotifier.value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    SharedPreferences.getInstance().then((p) => p.setString('theme_mode', v));
  });
  scanAllDirsNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setBool('scan_all_dirs', scanAllDirsNotifier.value));
  });
  scanDirsNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setStringList('scan_dirs', scanDirsNotifier.value));
  });
  keepBestNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setInt('keep_best', keepBestNotifier.value));
  });
  keepRuleNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setString('keep_rule', keepRuleNotifier.value));
  });
  keepDirNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setString('keep_dir', keepDirNotifier.value));
  });
  autoScanNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setBool('auto_scan', autoScanNotifier.value));
  });
  autoScanDaysNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setInt('auto_scan_days', autoScanDaysNotifier.value));
  });
  trashRetentionDaysNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setInt('trash_retention_days', trashRetentionDaysNotifier.value));
  });
}

/// 删除已下线功能的残留缓存文件（只跑一次，文件不存在则跳过）。
Future<void> _cleanOrphanCaches() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    for (final name in [
      'acoustic_fp_cache.json', // 音频指纹（已移除）
      'spectrum_cache.json', // 假无损频谱检测（已移除）
      'scan_cache.json', // 启动恢复扫描结果（已移除）
    ]) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) {
        await f.delete();
        debugPrint('[song_dedup] removed orphan cache $name');
      }
    }
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadSettings();
  await IgnoreService.load();
  _cleanOrphanCaches();
  // 清扫回收站孤儿文件（历史恢复 bug 留下的无记录副本），不阻塞启动
  TrashService.sweepOrphans();
  // 回收站过期自动清理（不阻塞启动）
  final retentionDays = trashRetentionDaysNotifier.value;
  if (retentionDays > 0) {
    TrashService.purgeExpired(Duration(days: retentionDays)).then((n) {
      if (n > 0) debugPrint('[song_dedup] trash auto-purged $n records');
    });
  }
  runApp(const SongDedupApp());
}

class SongDedupApp extends StatelessWidget {
  const SongDedupApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF616161),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF616161),
      brightness: Brightness.dark,
    );

    ThemeData theme(ColorScheme scheme) => ThemeData(
          colorScheme: scheme,
          useMaterial3: true,
          scaffoldBackgroundColor: scheme.surface,
          appBarTheme: AppBarTheme(
            backgroundColor: scheme.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
          ),
        );

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: '清聆',
        debugShowCheckedModeBanner: false,
        theme: theme(lightScheme),
        darkTheme: theme(darkScheme),
        themeMode: mode,
        home: const HomeScreen(),
      ),
    );
  }
}
