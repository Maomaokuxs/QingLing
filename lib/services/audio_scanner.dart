import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import '../models/song_file.dart';

class AudioScanner {
  static const _channel = MethodChannel('song_dedup/scanner');

  Future<List<SongFile>> scanAll() async {
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

    // 2. 调用原生 MediaStore 查询
    final List<dynamic> raw = await _channel.invokeMethod('querySongs');
    final result = <SongFile>[];
    for (final item in raw) {
      final m = Map<String, dynamic>.from(item as Map);
      final int duration = (m['duration'] as int?) ?? 0;
      if (duration < 30000) continue; // 过滤 <30s
      final String path = (m['path'] as String?) ?? '';
      if (path.isEmpty) continue;
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
        ),
      );
    }
    // 扫描目录过滤
    final dirs = scanDirsNotifier.value;
    if (dirs.isNotEmpty) {
      final filtered =
          result.where((s) => dirs.any((d) => s.path.startsWith(d))).toList();
      return filtered;
    }
    return result;
  }
}
