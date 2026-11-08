import 'song_file.dart';

/// 一组被判定为"同一首歌"的文件集合
class DuplicateGroup {
  final String key; // 分组key，比如 normalized title-artist
  final List<SongFile> songs; // 按音质从高到低排序
  final String displayTitle;
  final String reason; // 判定原因

  DuplicateGroup({
    required this.key,
    required this.songs,
    required this.displayTitle,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'songs': songs.map((s) => s.toJson()).toList(),
        'displayTitle': displayTitle,
        'reason': reason,
      };

  factory DuplicateGroup.fromJson(Map<String, dynamic> j) => DuplicateGroup(
        key: j['key'] as String,
        songs: (j['songs'] as List)
            .map((e) => SongFile.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        displayTitle: j['displayTitle'] as String,
        reason: j['reason'] as String,
      );

  /// 音质最差的1个（自动勾选候选）
  SongFile get worst => songs.last;

  /// 推荐保留的（音质最好）
  SongFile get best => songs.first;

  int get totalSize => songs.fold(0, (p, e) => p + e.sizeBytes);
}
