import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';

/// 全局主题模式：system 自动跟随系统，light/dark 手动切换
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);
/// 声纹开关（设置页可自由开启）
final ValueNotifier<bool> fingerprintEnabledNotifier = ValueNotifier(true);
/// 扫描目录：空表示全部，否则仅包含前缀匹配的路径
final ValueNotifier<List<String>> scanDirsNotifier = ValueNotifier([]);

Future<void> _loadSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final fp = prefs.getBool('fingerprint_enabled');
  if (fp != null) fingerprintEnabledNotifier.value = fp;
  final tm = prefs.getString('theme_mode');
  if (tm != null) {
    themeModeNotifier.value = switch (tm) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }
  final dirs = prefs.getStringList('scan_dirs');
  if (dirs != null) scanDirsNotifier.value = dirs;
  fingerprintEnabledNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setBool('fingerprint_enabled', fingerprintEnabledNotifier.value));
  });
  themeModeNotifier.addListener(() {
    final v = switch (themeModeNotifier.value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    SharedPreferences.getInstance().then((p) => p.setString('theme_mode', v));
  });
  scanDirsNotifier.addListener(() {
    SharedPreferences.getInstance().then((p) => p.setStringList('scan_dirs', scanDirsNotifier.value));
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadSettings();
  runApp(const SongDedupApp());
}

class SongDedupApp extends StatelessWidget {
  const SongDedupApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C4DFF),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C4DFF),
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
