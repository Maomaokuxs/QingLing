import 'dart:io';
import 'dart:math';

/// 单个音频文件模型
class SongFile {
  final int id; // MediaStore id
  final String path; // data
  final String displayName;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int sizeBytes;
  final String extension; // mp3, flac...
  /// MediaStore DATE_MODIFIED（秒）。缓存有效性校验用：
  /// 直接 FileStat 走文件路径在 scoped storage 下可能无权限，
  /// 用 MediaStore 列代替。0 表示未知。
  final int dateModified;
  /// MediaStore 读到的真实码率（kbps），取不到时为 0
  final int realBitrateKbps;

  // 计算得出
  late final int bitrateKbps; // 真实码率优先，取不到则按大小/时长估算
  late final int qualityScore; // 0-1000 分数越高音质越好
  late final String qualityLabel;

  /// 文件内容指纹：文件头 32KB 的 SHA-256。
  ///
  /// 注意：这是字节级哈希，不是声学指纹——转码或不同格式的同一首歌
  /// 哈希值完全不同。跨格式识别靠 [SimilarityService] 的时长锚定层，
  /// 不要把本指纹当作"声音相似"来用。
  String fingerprint = '';

  SongFile({
    required this.id,
    required this.path,
    required this.displayName,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.sizeBytes,
    required this.extension,
    this.realBitrateKbps = 0,
    this.dateModified = 0,
    String? fingerprint,
  }) {
    bitrateKbps =
        realBitrateKbps > 0 ? realBitrateKbps : _estimateBitrate();
    final qs = _calcQualityScore();
    qualityScore = qs.score;
    qualityLabel = qs.label;
    if (fingerprint != null) this.fingerprint = fingerprint;
  }

  /// isolate 传输用：Dart isolate 消息不支持自定义对象，先转 Map
  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'displayName': displayName,
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': durationMs,
        'sizeBytes': sizeBytes,
        'extension': extension,
        'realBitrateKbps': realBitrateKbps,
        'dateModified': dateModified,
        'fingerprint': fingerprint,
      };

  factory SongFile.fromJson(Map<String, dynamic> j) => SongFile(
        id: j['id'] as int,
        path: j['path'] as String,
        displayName: j['displayName'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String,
        album: j['album'] as String,
        durationMs: j['durationMs'] as int,
        sizeBytes: j['sizeBytes'] as int,
        extension: j['extension'] as String,
        realBitrateKbps: j['realBitrateKbps'] as int? ?? 0,
        dateModified: j['dateModified'] as int? ?? 0,
        fingerprint: j['fingerprint'] as String?,
      );

  int _estimateBitrate() {
    if (durationMs <= 0 || sizeBytes <= 0) return 0;
    // bitrate (kbps) = size*8 / duration(s) /1000
    return (sizeBytes * 8 / (durationMs / 1000) / 1000).round();
  }

  ({int score, String label}) _calcQualityScore() {
    // 格式权重: flac/wav 无损 > m4a/aac > mp3 > ogg/wma
    int formatScore = switch (extension.toLowerCase()) {
      'flac' => 400,
      'wav' => 380,
      'aiff' => 380,
      'm4a' || 'aac' => 250,
      'mp3' => 200,
      'ogg' => 180,
      'wma' => 120,
      _ => 100,
    };

    // 码率权重: 0-400分  320kbps算满分，无损按 ~900kbps 封顶
    int br = bitrateKbps.clamp(0, 1000);
    int bitrateScore;
    if (extension == 'flac' || extension == 'wav') {
      // 无损本身就高分，再叠加码率
      bitrateScore = min(400, (br * 0.4).round() + 50);
    } else {
      bitrateScore = min(400, (br / 320 * 400).round());
    }

    int total = formatScore + bitrateScore; // 0 ~ 800

    String label;
    if (total >= 700) {
      label = '无损';
    } else if (total >= 500) {
      label = '高音质';
    } else if (total >= 350) {
      label = '标准';
    } else {
      label = '较差';
    }
    return (score: total, label: label);
  }

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get formattedDuration {
    final s = (durationMs / 1000).round();
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  String get formattedBitrate =>
      bitrateKbps > 0 ? '${bitrateKbps}kbps' : '未知';

  bool existsSync() => File(path).existsSync();
}
