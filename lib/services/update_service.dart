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

  /// 查最新 release。网络超时 10 秒。
  static Future<UpdateCheckResult> checkForUpdate() async {
    String current;
    try {
      current = await AppVersion.get();
    } catch (_) {
      return const UpdateCheckResult(UpdateStatus.error, message: '无法读取当前版本');
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(_latestUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'QingLing');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 404) {
        return const UpdateCheckResult(UpdateStatus.noReleases);
      }
      if (resp.statusCode != 200) {
        return UpdateCheckResult(
          UpdateStatus.error,
          message: '服务器返回 ${resp.statusCode}',
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
    } on TimeoutException {
      return const UpdateCheckResult(UpdateStatus.error, message: '连接超时');
    } catch (e) {
      return UpdateCheckResult(UpdateStatus.error, message: e.toString());
    } finally {
      client.close();
    }
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
  /// [onProgress] 回调（已收字节，总字节；总字节未知时为 -1）。
  /// 传入 [client] 时由调用方持有，可在取消时 client.close(force: true)
  /// 中断下载；不传则内部新建。
  static Future<String> downloadApk(
    String url,
    void Function(int received, int total) onProgress, {
    HttpClient? client,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/qingling-update.apk');
    final httpClient = client ?? HttpClient();
    httpClient.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await httpClient.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'QingLing');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.close();
      return file.path;
    } finally {
      if (client == null) httpClient.close();
    }
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
