import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import '../models/song_file.dart';

class AudioScanner {
  static const _channel = MethodChannel('song_dedup/scanner');

  /// [includeShort]：是否包含 30 秒以下的短音频（游戏 BGM、片段等）。
  /// 默认 false：短于 30 秒的不扫；扫描时弹框询问用户，选了才包含。
  ///
  /// [cachedSongs]：上次扫描缓存的全部文件（path → SongFile）。
  /// 传了它，原生层对 mtime+size 未变的文件跳过读元数据、只回 path
  /// （带 cached: true），这里直接用缓存的 SongFile，省掉十几秒。
  /// [onMediaProgress]：原生媒体扫描进度回调（阶段，0~1 的媒体扫描进度，
  /// 已处理数，总数）。阶段 walk=遍历目录（占大头），meta=读元数据。
  Future<List<SongFile>> scanAll({
    bool includeShort = false,
    Map<String, SongFile>? cachedSongs,
    void Function(String stage, double fraction, int processed, int total)?
        onMediaProgress,
  }) async {
    // 1. 请求权限 - 适配 Android 13+ READ_MEDIA_AUDIO 与旧版 READ_EXTERNAL_STORAGE
    Permission perm = Permission.audio;
    // permission_handler 的 Permission.audio 在 Android 13+ 对应 READ_MEDIA_AUDIO
    // 在旧版本自动映射到 READ_EXTERNAL_STORAGE
    var status = await perm.status;
    if (!status.isGranted) {
      status = await perm.request();
      // 部分ROM上 audio 权限被拒，尝试 storage
      if (!status.isGranted) {
        var s2 = await Permission.storage.request();
        if (!s2.isGranted && !status.isGranted) {
          throw Exception('未授予音频读取权限，请在系统设置中允许"音乐与音频"权限');
        }
      }
    }

    // 原生进度回调：querySongsFromFs 在后台线程处理文件时定期上报。
    if (onMediaProgress != null) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'scanProgress') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final stage = (args['stage'] as String?) ?? 'meta';
          final processed = (args['processed'] as num?)?.toInt() ?? 0;
          final total = (args['total'] as num?)?.toInt() ?? 0;
          final fraction =
              total <= 0 ? 0.0 : (processed / total).clamp(0.0, 1.0);
          onMediaProgress(stage, fraction, processed, total);
        }
        return null;
      });
    }

    // 2. 文件系统直扫（主路径）：对选中目录递归列文件，不依赖 MediaStore 枚举。
    // MediaStore 经常漏索引文件（经 MTP/adb 拷入的 (1)~(5) 副本），文件在磁盘上
    // 就一定能扫到。失败时回退到 MediaStore 查询。
    late final List<dynamic> raw;
    try {
      final dirs = scanAllDirsNotifier.value
          ? <String>[]
          : List<String>.from(scanDirsNotifier.value);
      // 缓存的 path → [dateModified, sizeBytes]，供原生跳过未变文件；
      // expectedTotal=上次扫描总数，供原生遍历时估算进度分母
      final cached = <String, List<int>>{};
      if (cachedSongs != null) {
        for (final e in cachedSongs.entries) {
          cached[e.key] = [e.value.dateModified, e.value.sizeBytes];
        }
      }
      raw = await _channel.invokeMethod('querySongsFromFs', {
        'dirs': dirs,
        'cached': cached,
        'expectedTotal': cachedSongs?.length ?? 0,
      });
    } catch (_) {
      // 回退：MediaStore 查询
      raw = await _channel.invokeMethod('querySongs');
    } finally {
      // 进度回调只在本次扫描内有效，避免旧 handler 残留
      if (onMediaProgress != null) {
        _channel.setMethodCallHandler(null);
      }
    }
    final result = <SongFile>[];
    for (final item in raw) {
      final m = Map<String, dynamic>.from(item as Map);
      final String path = (m['path'] as String?) ?? '';
      if (path.isEmpty) continue;
      // 原生跳过的文件：直接用缓存的 SongFile
      if (m['cached'] == true) {
        final cachedSong = cachedSongs?[path];
        if (cachedSong != null) result.add(cachedSong);
        continue;
      }
      final int duration = (m['duration'] as int?) ?? 0;
      if (duration <= 0) continue; // 无时长信息，无法分组
      // 短于 30 秒默认不扫（铃声/提示音）；开关打开时也扫（游戏 BGM、片段等）
      if (!includeShort && duration < 30000) continue;
      final String displayName =
          (m['displayName'] as String?) ?? (m['title'] as String? ?? '');
      final String ext = displayName.contains('.')
          ? displayName.split('.').last.toLowerCase()
          : (path.contains('.') ? path.split('.').last.toLowerCase() : 'mp3');
      const audioExts = {
        'mp3',
        'flac',
        'wav',
        'm4a',
        'aac',
        'ogg',
        'wma',
        'opus',
        'aiff',
        'mp2'
      };
      if (!audioExts.contains(ext)) continue;

      result.add(
        SongFile(
          id: (m['id'] as int?) ?? 0,
          path: path,
          displayName: displayName,
          title: ((m['title'] as String?) ?? '').trim(),
          artist: ((m['artist'] as String?) ?? '<unknown>').trim(),
          album: ((m['album'] as String?) ?? '').trim(),
          durationMs: duration,
          sizeBytes: (m['size'] as int?) ?? 0,
          extension: ext,
          // MediaStore 的 bitrate 单位是 bps，转 kbps；取不到则为 0，
          // SongFile 会回退到按大小/时长估算
          realBitrateKbps: ((m['bitrate'] as int?) ?? 0) ~/ 1000,
          dateModified: (m['dateModified'] as int?) ?? 0,
        ),
      );
    }
    // 扫描范围过滤：全部目录 或 仅扫描勾选的目录（前缀匹配）。
    // 文件系统直扫已按目录过滤，这里是 MediaStore 回退路径的保障。
    if (scanAllDirsNotifier.value) return result;
    final dirs = scanDirsNotifier.value;
    return result.where((s) => dirs.any((d) => s.path.startsWith(d))).toList();
  }
}
