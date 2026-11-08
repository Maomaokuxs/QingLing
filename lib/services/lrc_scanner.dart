import 'package:flutter/services.dart';

/// LRC 歌词文件模型
class LrcFile {
  final int id;
  final String path;
  final String displayName;
  final int sizeBytes;
  String contentHash = '';

  LrcFile({
    required this.id,
    required this.path,
    required this.displayName,
    required this.sizeBytes,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// LRC 歌词扫描与去重
class LrcScanner {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// 查询所有 .lrc 文件
  static Future<List<LrcFile>> scanAll() async {
    final List<dynamic> raw = await _ch.invokeMethod('queryLrcFiles');
    return raw.map((item) {
      final m = Map<String, dynamic>.from(item as Map);
      return LrcFile(
        id: (m['id'] as int?) ?? 0,
        path: (m['path'] as String?) ?? '',
        displayName: (m['displayName'] as String?) ?? '',
        sizeBytes: ((m['size'] as num?) ?? 0).toInt(),
      );
    }).where((f) => f.path.isNotEmpty).toList();
  }

  /// 计算文件内容 SHA-256
  static Future<String> contentHash(LrcFile f) async {
    try {
      final r = await _ch.invokeMethod(
          'fileContentHash', {'id': f.id, 'path': f.path}).timeout(
          const Duration(seconds: 15));
      return r as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 按内容哈希分组，返回有重复的组（>=2 个）
  static Future<List<List<LrcFile>>> findDuplicates(
      {void Function(int done, int total)? onProgress}) async {
    final all = await scanAll();
    // 先按大小分组，大小唯一的直接跳过
    final bySize = <int, List<LrcFile>>{};
    for (final f in all) {
      bySize.putIfAbsent(f.sizeBytes, () => []).add(f);
    }
    final candidates =
        bySize.values.where((v) => v.length > 1).expand((v) => v).toList();
    // 对候选计算内容哈希
    final byHash = <String, List<LrcFile>>{};
    var done = 0;
    for (final f in candidates) {
      f.contentHash = await contentHash(f);
      if (f.contentHash.isNotEmpty) {
        byHash.putIfAbsent(f.contentHash, () => []).add(f);
      }
      done++;
      onProgress?.call(done, candidates.length);
    }
    return byHash.values.where((v) => v.length > 1).toList();
  }

  /// 删除 LRC 文件（走系统删除确认）
  static Future<bool> deleteFiles(List<LrcFile> files) async {
    try {
      final r = await _ch.invokeMethod('deleteLrcFiles', {
        'ids': files.map((f) => f.id).toList(),
        'paths': files.map((f) => f.path).toList(),
      });
      return r == true;
    } catch (_) {
      return false;
    }
  }
}
