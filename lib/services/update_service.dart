import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_version.dart';

/// 一条可用更新：对应 GitHub 上最新 release 里的 APK 资源。
class UpdateInfo {
  /// release 的 tag，如 v0.2.1。
  final String tag;

  /// release 标题。
  final String name;

  /// release 说明（更新日志）。
  final String notes;

  /// APK 下载地址（release 资源的 browser_download_url）。
  final String apkUrl;

  /// APK 大小（字节），-1 表示未知。
  final int apkSizeBytes;

  const UpdateInfo({
    required this.tag,
    required this.name,
    required this.notes,
    required this.apkUrl,
    required this.apkSizeBytes,
  });

  /// 从 GitHub latest release 的 JSON 解析。无 APK 资源返回 null。
  static UpdateInfo? fromReleaseJson(Map<String, dynamic> j) {
    final assets = j['assets'];
    if (assets is! List) return null;
    Map<String, dynamic>? apk;
    for (final a in assets) {
      if (a is! Map) continue;
      final m = Map<String, dynamic>.from(a);
      final name = (m['name'] as String? ?? '').toLowerCase();
      if (name.endsWith('.apk')) {
        apk = m;
        break;
      }
    }
    if (apk == null) return null;
    final url = apk['browser_download_url'] as String? ?? '';
    if (url.isEmpty) return null;
    return UpdateInfo(
      tag: j['tag_name'] as String? ?? '',
      name: j['name'] as String? ?? '',
      notes: j['body'] as String? ?? '',
      apkUrl: url,
      apkSizeBytes: (apk['size'] as num?)?.toInt() ?? -1,
    );
  }

  /// 去掉 tag 前缀 v 后的版本号，如 v0.2.1 → 0.2.1。
  String get version =>
      tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
}

enum UpdateStatus {
  /// 已是最新版本。
  upToDate,

  /// 有新版本。
  available,

  /// 仓库还没有任何 release。
  noReleases,

  /// 检查失败（网络、限流等）。
  error,
}

class UpdateCheckResult {
  final UpdateStatus status;
  final UpdateInfo? info;

  /// 仅 error 时有内容。
  final String message;

  const UpdateCheckResult(this.status, {this.info, this.message = ''});
}

/// 更新检查：查 GitHub 最新 release，与当前版本比对。
///
/// release 的 tag 约定为 v<versionName>，如 v0.2.1；
/// 只比 versionName（0.2.1），不比 build 号（+2026 是开发构建计数）。
/// 未登录调用额度按手机自身 IP 计（每小时 60 次），偶尔检查足够用。
class UpdateService {
  static const _latestUrl =
      'https://api.github.com/repos/Maomaokuxs/QingLing/releases/latest';
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 经原生 HttpURLConnection GET（走 Android 系统解析，能感知 VPN/Clash，
  /// Dart 的 HttpClient 读不到系统 DNS 时解析失败）。
  /// 返回 {status, location, body}；网络异常时抛 PlatformException。
  static Future<Map<String, dynamic>> _nativeGet(
    String url, {
    bool followRedirects = true,
  }) async {
    final res = await _ch.invokeMethod<Map<dynamic, dynamic>>(
      'httpGet',
      {'url': url, 'followRedirects': followRedirects},
    );
    return Map<String, dynamic>.from(res ?? {});
  }

  /// 查最新 release。网络超时 10 秒。
  ///
  /// 先走 api.github.com；网络失败时改走 github.com 网页重定向兜底。
  static Future<UpdateCheckResult> checkForUpdate() async {
    String current;
    try {
      current = await AppVersion.get();
    } catch (_) {
      return const UpdateCheckResult(UpdateStatus.error, message: '无法读取当前版本');
    }
    try {
      final apiResult = await _checkViaApi(current);
      if (apiResult.status != UpdateStatus.error) {
        return apiResult;
      }
      // API 报错（如 403 限流）时也改走网页兜底；网页没有 API 的限流。
      return _checkViaWeb(current);
    } on PlatformException {
      return _checkViaWeb(current);
    }
  }

  /// 走 GitHub API 查最新 release。网络异常（PlatformException）不吞，
  /// 直接抛给上层兜底。
  static Future<UpdateCheckResult> _checkViaApi(String current) async {
    final res = await _nativeGet(_latestUrl);
    final status = res['status'] as int? ?? 0;
    final body = res['body'] as String? ?? '';
    if (status == 404) {
      return const UpdateCheckResult(UpdateStatus.noReleases);
    }
    if (status != 200) {
      return UpdateCheckResult(
        UpdateStatus.error,
        message: '服务器返回 $status',
      );
    }
    final raw = jsonDecode(body);
    if (raw is! Map<String, dynamic>) {
      return const UpdateCheckResult(UpdateStatus.error, message: '返回数据异常');
    }
    final info = UpdateInfo.fromReleaseJson(raw);
    if (info == null) {
      return const UpdateCheckResult(UpdateStatus.noReleases);
    }
    if (isNewerVersion(info.version, current)) {
      return UpdateCheckResult(UpdateStatus.available, info: info);
    }
    return const UpdateCheckResult(UpdateStatus.upToDate);
  }

  /// 网页兜底：github.com/releases/latest 会 302 到最新 release 的 tag 页，
  /// 从 Location 里取 tag；下载地址按发布命名规则拼。
  /// 仅在 API 路径因网络失败时调用。
  static const _webLatestUrl =
      'https://github.com/Maomaokuxs/QingLing/releases/latest';

  static Future<UpdateCheckResult> _checkViaWeb(String current) async {
    Map<String, dynamic> res;
    try {
      res = await _nativeGet(_webLatestUrl, followRedirects: false);
    } on PlatformException catch (e) {
      return UpdateCheckResult(UpdateStatus.error, message: _nativeError(e));
    }
    final status = res['status'] as int? ?? 0;
    if (status == 404) {
      return const UpdateCheckResult(UpdateStatus.noReleases);
    }
    if (status != 302 && status != 301) {
      return UpdateCheckResult(
        UpdateStatus.error,
        message: '服务器返回 $status',
      );
    }
    final tag = tagFromLocation(res['location'] as String? ?? '');
    if (tag.isEmpty) {
      return const UpdateCheckResult(UpdateStatus.error, message: '返回数据异常');
    }
    final version = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    if (isNewerVersion(version, current)) {
      return UpdateCheckResult(
        UpdateStatus.available,
        info: UpdateInfo(
          tag: tag,
          name: tag,
          notes: '',
          apkUrl:
              'https://github.com/Maomaokuxs/QingLing/releases/download/$tag/QingLing-$version-arm64.apk',
          apkSizeBytes: -1,
        ),
      );
    }
    return const UpdateCheckResult(UpdateStatus.upToDate);
  }

  /// 原生 HTTP 异常文案取短一点，去掉 "HTTP_ERROR: " 前缀与异常类名。
  static String _nativeError(PlatformException e) {
    final m = e.message ?? e.toString();
    final idx = m.indexOf(': ');
    return idx >= 0 ? m.substring(idx + 2) : m;
  }

  /// 从重定向 Location 取 tag，如
  /// https://github.com/Maomaokuxs/QingLing/releases/tag/v0.2.1 → v0.2.1。
  /// 相对地址也行。取不到返回 ''。
  static String tagFromLocation(String location) {
    if (location.isEmpty) return '';
    final uri = Uri.tryParse(location);
    if (uri == null || uri.pathSegments.isEmpty) return '';
    return uri.pathSegments.last;
  }

  /// release 版本是否比当前新。只比 X.Y.Z，不比 build 号。
  /// 任一解析失败返回 false（不报假更新）。
  static bool isNewerVersion(String release, String current) {
    final r = _parseSemver(release);
    final c = _parseSemver(current);
    if (r == null || c == null) return false;
    for (var i = 0; i < 3; i++) {
      if (r[i] != c[i]) return r[i] > c[i];
    }
    return false;
  }

  /// 解析 X.Y.Z（缺段补 0；带 build 号如 0.2.1+2026 只取 + 前面；
  /// tag 前缀 v 如 v0.2.2 先去掉）。解析失败返回 null。
  static List<int>? _parseSemver(String v) {
    var core = v.split('+').first.trim();
    if (core.startsWith('v') || core.startsWith('V')) {
      core = core.substring(1);
    }
    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return nums;
  }

  /// 下载 APK 到缓存目录，返回文件路径。
  /// 走原生 HttpURLConnection（与检查更新同理，Dart HttpClient 解析不到）。
  /// [onProgress] 回调（已收字节，总字节；总字节未知时为 -1）。
  /// 取消用 [cancelDownload]，不再传 HttpClient。
  static const _updateCh = MethodChannel('song_dedup/update');

  static Future<String> downloadApk(
    String url,
    void Function(int received, int total) onProgress,
  ) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/qingling-update.apk');
    _updateCh.setMethodCallHandler((call) async {
      if (call.method == 'downloadProgress') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final received = (args['received'] as num?)?.toInt() ?? 0;
        final total = (args['total'] as num?)?.toInt() ?? -1;
        onProgress(received, total);
      }
    });
    try {
      final path = await _updateCh.invokeMethod<String>(
        'downloadFile',
        {'url': url, 'destPath': file.path},
      );
      if (path == null || path.isEmpty) throw Exception('下载失败');
      return path;
    } finally {
      _updateCh.setMethodCallHandler(null);
    }
  }

  /// 取消正在进行的原生下载。
  static Future<void> cancelDownload() async {
    try {
      await _updateCh.invokeMethod<bool>('cancelDownload');
    } catch (_) {}
  }

  /// 调原生安装器安装指定 APK。返回是否成功调起安装界面。
  /// 首次安装需用户在系统提示里允许「安装未知应用」。
  static Future<bool> installApk(String path) async {
    try {
      final ok = await _ch.invokeMethod<bool>('installApk', {'path': path});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
