// 预留：未来可扩展频谱分析等
// 目前音质逻辑在 SongFile 模型内已实现
// 这里提供工具函数用于排序与自动选择

import '../models/song_file.dart';

class QualityService {
  /// 按音质从高到低排序
  static List<SongFile> sortByQualityDesc(List<SongFile> list) {
    final copy = List<SongFile>.from(list);
    copy.sort((a, b) => b.qualityScore.compareTo(a.qualityScore));
    return copy;
  }

  /// 自动选择音质较差的 n 个（默认保留最好的1个，选中其余）
  static Set<String> autoSelectWorst(List<SongFile> sortedDesc, {int keepBest = 1}) {
    if (sortedDesc.length <= keepBest) return {};
    return sortedDesc.sublist(keepBest).map((e) => e.path).toSet();
  }

  static const _losslessExts = {'flac', 'wav', 'aiff', 'aif', 'alac', 'ape'};

  /// 按保留规则排序（从高到低）：quality=音质分，lossless=无损优先，
  /// dir=指定目录优先（目录内再按音质）
  static List<SongFile> sortByRuleDesc(
      List<SongFile> list, String rule, String preferredDir) {
    final copy = List<SongFile>.from(list);
    bool isLossless(SongFile s) =>
        _losslessExts.contains(s.extension.toLowerCase());
    copy.sort((a, b) {
      if (rule == 'lossless') {
        final la = isLossless(a) ? 1 : 0;
        final lb = isLossless(b) ? 1 : 0;
        if (la != lb) return lb.compareTo(la);
      } else if (rule == 'dir' && preferredDir.isNotEmpty) {
        final da = a.path.startsWith(preferredDir) ? 1 : 0;
        final db = b.path.startsWith(preferredDir) ? 1 : 0;
        if (da != db) return db.compareTo(da);
      }
      return b.qualityScore.compareTo(a.qualityScore);
    });
    return copy;
  }

  /// 按规则自动选择待删除（保留每组最好的 keepBest 个）
  static Set<String> autoSelectByRule(List<SongFile> songs,
      {int keepBest = 1, String rule = 'quality', String preferredDir = ''}) {
    final sorted = sortByRuleDesc(songs, rule, preferredDir);
    if (sorted.length <= keepBest) return {};
    return sorted.sublist(keepBest).map((e) => e.path).toSet();
  }
}
