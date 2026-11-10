import 'package:package_info_plus/package_info_plus.dart';

/// 应用版本：运行时读包信息（与 pubspec.yaml 同步），不再手写版本号。
/// 格式：versionName+buildNumber，如 0.2.1+2020。
/// 带进程内缓存，读一次后不再调平台通道。
class AppVersion {
  static Future<String>? _cached;

  static Future<String> get() {
    return _cached ??= PackageInfo.fromPlatform()
        .then((i) => '${i.version}+${i.buildNumber}');
  }
}
