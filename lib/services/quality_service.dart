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
}
