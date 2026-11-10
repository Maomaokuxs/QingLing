import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import 'chroma_fp_cache.dart';
import 'chroma_fingerprint_service.dart';
import 'fingerprint_cache.dart';
import 'isolate_pool.dart';
import 'quality_service.dart';
import 'spectral_analysis_service.dart';
import 'spectral_cache.dart';

/// 每首歌预计算一次的相似度键。
/// 原逻辑在 O(n²) 内层对每对歌曲反复做 toLowerCase/归一化/分词，
/// 大曲库下是主要耗时；预计算后内层只做集合交集。
class _SimKey {
  final String path;
  final int durationMs;
  final String normKey; // _normalizeKey（含歌手）
  final String normTitle; // _normText(标题)
  final String lowerTitle; // (title/displayName).toLowerCase()
  final String lowerName; // displayName.toLowerCase()
  final String artist; // 原始歌手（Tier 3 歌手兼容检查用）
  final Set<String> normTitleBigrams;
  final Set<String> titleBigrams;
  final Set<String> nameBigrams;

  const _SimKey({
    required this.path,
    required this.durationMs,
    required this.normKey,
    required this.normTitle,
    required this.lowerTitle,
    required this.lowerName,
    required this.artist,
    required this.normTitleBigrams,
    required this.titleBigrams,
    required this.nameBigrams,
  });
}

class SimilarityService {
  /// 分组逻辑版本号：改动任何分组/细分/兼容判定逻辑时必须 +1。
  /// ScanCache 靠它判断缓存是否过期——版本对不上就丢弃缓存、全量重扫，
  /// 否则一次错分组会靠增量扫描永远复用下去（一次错、次次错）。
  /// 历史：1 = 初始逻辑；2 = 版本关键词加 Live/Remix/不插电/Demo，
  /// 歌手笔误容忍封顶 2 处；3 = Tier 1 时长细拆阈值 15s → 2s
  /// （「以太虚境++」19.2s 与「以太虚境」24.0s 曾被合成一组）；
  /// 4 = Tier 1 组 key 加时长桶（同上两组曾撞 key，selections 互覆）。
  static const int groupingVersion = 9;

  /// 主入口：四层递进，每层只处理上层剩下的歌曲。
  ///
  /// 宁可漏过，不可错选：分组时证据不足 → 不分组（漏过）；细分时
  /// 有疑点 → 拆组（漏过）；不确定的组永不自动删除。
  ///
  /// 1. 粗分组：归一化标题相同 + 歌手兼容（最常见：同标题同歌手多版本）。
  ///    歌手完全不同 → 不分组。
  /// 2. 时长锚定：同时长（±2s）+ 歌手兼容 + 标题相近（归一化标题相似度 ≥0.9）
  ///    + 文件大小比合理（≤30x，防时长撞车）→ 跨格式/转码副本。
  /// 3. 模糊匹配：标题相似度（≥0.9）+ 时长相近 + 歌手兼容。
  /// 4. 文件内容哈希全等：字节级相同的副本（文件名不同也认得）。
  ///    注意这是字节哈希不是声学指纹，转码过的认不出——那是第 2 层的事。
  ///
  /// 组内验证层（Tier 1~3 出组后，subdivideByMetadata）：对每个组跑元数据
  /// 兼容检查（脚本/版本关键词/歌手/feat.），有不兼容的对 → 拆成
  /// reason='同名不同版本' 的新组。防 Tier 1 错分一路带下去。
  /// 注意 Tier 4（文件哈希）组不经过这层：字节相同即同一音频，
  /// 元数据差异只是标签差异，不拆。
  ///
  /// 组内元数据版本检测（不走开关，每次扫描都做，纯字符串比对）：
  /// 同名组内用文字脚本/版本关键词/歌手区分不同语言/版本。
  /// 不同版本拆成新组（reason='同名不同版本'，noAutoSelect=true，
  /// 不自动勾选、不进删除项）。chroma 抓旋律，分辨不了同旋律换语言。
  ///
  /// 组内版本细分（enableCrossLingual=true 时）：对 Tier 1 同名组做 chroma
  /// 二次验证，同一录音保留原组，不同版本/语言拆成新组（reason='同名不同版本'，
  /// noAutoSelect=true，不自动勾选、不进删除项）。
  static Future<List<DuplicateGroup>> groupSimilarSongsWithFingerprint(
    List<SongFile> all, {
    double titleThreshold = 0.9,
    int durationToleranceMs = 5000,
    bool enableFingerprint = true,
    bool enableCrossLingual = false,
    bool enableSpectral = false,
    void Function(int done, int total)? onProgress,
    void Function(int done, int total)? onChromaProgress,
    void Function(int done, int total)? onSpectralProgress,
    // 分阶段耗时（毫秒），由调用方传入空 Map，方法内填入，供扫描历史统计。
    Map<String, int>? stageMs,
  }) async {
    if (all.isEmpty) return [];
    // Tier 1~3：同步 CPU 密集计算（O(n²) 字符串比对），在后台 isolate
    // 执行，避免大曲库卡住 UI 线程导致界面冻结/ANR。
    // isolate 消息不支持自定义对象，边界处用 JSON 序列化。
    final songsJson = all.map((s) => s.toJson()).toList();
    var sw = Stopwatch()..start();
    final syncOut = await Isolate.run<Map<String, dynamic>>(
      () => _syncTiersJson(<String, dynamic>{
        'songs': songsJson,
        'durationToleranceMs': durationToleranceMs,
        'titleThreshold': titleThreshold,
      }),
    );
    stageMs?['tier123Ms'] = sw.elapsedMilliseconds;
    var result = (syncOut['groups'] as List)
        .map((e) => DuplicateGroup.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    // 组内验证层（见类文档）：Tier 1~3 出组后跑元数据兼容检查，
    // 不兼容的对拆成 reason='同名不同版本' 的新组。不同版本拆出且
    // 不自动勾选，不进删除项。
    sw = Stopwatch()..start();
    result = subdivideByMetadata(result);
    stageMs?['metadataMs'] = sw.elapsedMilliseconds;

    // 组内版本细分（设置页"组内版本细分"开关）：同一标题/歌手下，用 chroma 指纹
    // 区分同一录音与不同版本/语言。不同版本拆出且不自动勾选，不进删除项。
    // 关闭则跳过，扫描更快。
    if (enableCrossLingual) {
      sw = Stopwatch()..start();
      result = await _subdivideTitleGroupsByChroma(result,
          onProgress: onChromaProgress);
      stageMs?['chromaMs'] = sw.elapsedMilliseconds;
    } else {
      stageMs?['chromaMs'] = 0;
    }

    // Tier 4: 文件内容哈希（可开关，IO 开销大）
    // 候选 = 所有不在最终组里的歌：既包括 Tier 1~3 未分组的 remaining，
    // 也包括被元数据/chroma 细分拆成单首后丢弃的。字节完全相同的文件
    // 必须在这里被抓回——以前只跑 remaining，拆成单首的漏网
    // （三Z-STUDIO (1)(2) 副本案）。字节相同即同一音频，元数据差异
    // 只是标签差异，Tier 4 组不经过元数据细分。
    if (enableFingerprint) {
      final inResult =
          result.expand((g) => g.songs.map((s) => s.path)).toSet();
      final tier4Candidates =
          all.where((s) => !inResult.contains(s.path)).toList();
      stageMs?['tier4Candidates'] = tier4Candidates.length;
      if (tier4Candidates.length >= 2) {
        sw = Stopwatch()..start();
        final gs = await _fileHashGroups(
          tier4Candidates,
          durationToleranceMs,
          onProgress,
        );
        stageMs?['fileHashMs'] = sw.elapsedMilliseconds;
        result.addAll(gs);
      } else {
        stageMs?['fileHashMs'] = 0;
      }
    } else {
      stageMs?['tier4Candidates'] = 0;
      stageMs?['fileHashMs'] = 0;
    }

    // 假无损检测（设置页"假无损检测"开关，默认关）：对组内无损文件做
    // 频谱分析，填入 spectral 字段，再按有效音质分重排各组（假 FLAC
    // 降级，不再排第一、不会被保留）。只分析组内文件（待删决策只与
    // 组内比较有关），全库无损不逐个分析。关闭则跳过，扫描更快。
    if (enableSpectral) {
      sw = Stopwatch()..start();
      result = await _analyzeSpectralInGroups(result,
          onProgress: onSpectralProgress);
      stageMs?['spectralMs'] = sw.elapsedMilliseconds;
    } else {
      stageMs?['spectralMs'] = 0;
    }

    // 按组大小排序：大组优先
    result.sort((a, b) => b.songs.length.compareTo(a.songs.length));
    return result;
  }

  /// 对各组内的无损文件做频谱截止分析（假无损检测）。
  ///
  /// 带缓存（path + mtime 绑定，文件未变直接复用）。分析完把结果
  /// 填到 SongFile.spectral，再按有效音质分重排各组——假无损降级
  /// 后排到真高音质后面，自动勾选就不会误删真货、保留假货。
  static Future<List<DuplicateGroup>> _analyzeSpectralInGroups(
    List<DuplicateGroup> groups, {
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = <SongFile>[];
    for (final g in groups) {
      for (final s in g.songs) {
        if (SpectralAnalysisService.isLosslessExt(s.extension)) {
          targets.add(s);
        }
      }
    }
    if (targets.isEmpty) return groups;
    final cache = await SpectralCache.load();
    var done = 0;
    var changed = false;
    for (final s in targets) {
      var r = cache.lookup(s.path, s.dateModified);
      if (r == null) {
        r = await SpectralAnalysisService.analyze(s.id, s.path);
        if (r != null) {
          cache.store(s.path, s.dateModified, r);
          changed = true;
        }
      }
      if (r != null) s.spectral = r;
      done++;
      onProgress?.call(done, targets.length);
    }
    if (changed) await cache.save();
    return groups.map((g) {
      if (g.songs.any((s) => s.isFakeLossless)) {
        return DuplicateGroup(
          key: g.key,
          songs: QualityService.sortByQualityDesc(g.songs),
          displayTitle: g.displayTitle,
          reason: g.reason,
          noAutoSelect: g.noAutoSelect,
        );
      }
      return g;
    }).toList();
  }

  /// 增量分组：重扫时只处理新增/变更文件，旧组直接复用。
  ///
  /// - [newSongs]：新增或内容变更（mtime/size 对不上）的文件；
  /// - [oldSongs]：未变的文件（新鲜元数据）；
  /// - [oldGroups]：已刷新过的旧组（删除/变更已剔除，<2 首已丢弃）。
  ///
  /// 做法：新文件先通过标题 key / 时长窗口找到可能匹配的旧歌
  /// （候选旧歌，含未分组的旧歌），再把"新文件 + 候选旧歌 +
  /// 候选旧歌所在的旧组"取并集，用完整流程
  /// [groupSimilarSongsWithFingerprint] 重算该并集，
  /// 未触碰的旧组原样保留。
  ///
  /// 候选旧歌的覆盖性：Tier 1 要求同标题 key；Tier 2/3 要求时长在
  /// 容差内（±durationToleranceMs 覆盖 Tier 2 的 2s 与 Tier 3 的 5s，
  /// 含标题/文件名相似兜底）；Tier 4 要求哈希相同——同哈希即同字节，
  /// 同字节时长必然相同，也落在时长窗口里。三种情况都被标题/时长
  /// 索引覆盖，新文件不会漏掉与旧文件的重复（除 duration=0 的极端脏数据）。
  static Future<List<DuplicateGroup>> groupIncremental({
    required List<SongFile> newSongs,
    required List<SongFile> oldSongs,
    required List<DuplicateGroup> oldGroups,
    double titleThreshold = 0.9,
    int durationToleranceMs = 5000,
    bool enableFingerprint = true,
    bool enableCrossLingual = false,
    bool enableSpectral = false,
    void Function(int done, int total)? onProgress,
    void Function(int done, int total)? onChromaProgress,
    void Function(int done, int total)? onSpectralProgress,
    // 分阶段耗时（毫秒），透传给全量分组方法，供扫描历史统计。
    Map<String, int>? stageMs,
  }) async {
    if (newSongs.isEmpty) return oldGroups;

    // 候选旧歌：与任一新文件同标题 key，或时长在 ±durationToleranceMs 内。
    // 覆盖性：Tier 1 要求同标题 key；Tier 2 要求时长 ±2s；
    // Tier 3 要求时长 ±durationToleranceMs（标题/文件名相似兜底都走这条）；
    // Tier 4 要求哈希相同——同哈希即同字节，同字节时长必然相同，
    // 也落在时长窗口里。三种情况都被标题/时长索引覆盖，
    // 新文件不会漏掉与旧文件的重复（除 duration=0 的极端脏数据）。
    final titleIndex = <String, List<SongFile>>{};
    for (final s in oldSongs) {
      final key = _normText(s.title.isNotEmpty ? s.title : s.displayName);
      if (key.length >= 2) {
        titleIndex.putIfAbsent(key, () => []).add(s);
      }
    }
    final matchedOld = <SongFile>[];
    final matchedOldPaths = <String>{};
    void addMatched(SongFile s) {
      if (matchedOldPaths.add(s.path)) matchedOld.add(s);
    }

    for (final n in newSongs) {
      final key = _normText(n.title.isNotEmpty ? n.title : n.displayName);
      if (key.length >= 2) {
        for (final s in titleIndex[key] ?? const <SongFile>[]) {
          addMatched(s);
        }
      }
      for (final s in oldSongs) {
        if ((s.durationMs - n.durationMs).abs() <= durationToleranceMs) {
          addMatched(s);
        }
      }
    }

    // 被触碰的旧组：含任一候选旧歌。未触碰的旧组原样保留。
    final untouched = <DuplicateGroup>[];
    final touchedSongs = <SongFile>[];
    for (final grp in oldGroups) {
      if (grp.songs.any((s) => matchedOldPaths.contains(s.path))) {
        touchedSongs.addAll(grp.songs);
      } else {
        untouched.add(grp);
      }
    }

    // 并集重算：新文件 + 候选旧歌（含未分组的旧歌，新文件可能与它们重复）
    // + 被触碰旧组的全部歌曲。并集通常很小，全量流程便宜，
    // 且 Tier 1 的时长拆分、歌手聚类、细分等逻辑与全量扫描完全一致。
    final subset = <SongFile>[];
    final seen = <String>{};
    for (final s in [...newSongs, ...matchedOld, ...touchedSongs]) {
      if (seen.add(s.path)) subset.add(s);
    }
    final rederived = await groupSimilarSongsWithFingerprint(
      subset,
      titleThreshold: titleThreshold,
      durationToleranceMs: durationToleranceMs,
      enableFingerprint: enableFingerprint,
      enableCrossLingual: enableCrossLingual,
      enableSpectral: enableSpectral,
      onProgress: onProgress,
      onChromaProgress: onChromaProgress,
      onSpectralProgress: onSpectralProgress,
      stageMs: stageMs,
    );

    final result = [...untouched, ...rederived];
    result.sort((a, b) => b.songs.length.compareTo(a.songs.length));
    return result;
  }

  /// Tier 1~3 的同步分组逻辑，仅在后台 isolate 内执行。
  /// 入参/返回值均为 JSON 兼容类型；内部只调用纯静态方法。
  static Map<String, dynamic> _syncTiersJson(Map<String, dynamic> args) {
    final songs = (args['songs'] as List)
        .map((e) => SongFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final durationToleranceMs = args['durationToleranceMs'] as int;
    final titleThreshold = (args['titleThreshold'] as num).toDouble();

    final result = <DuplicateGroup>[];
    var remaining = List<SongFile>.from(songs);

    void takeTier(List<DuplicateGroup> Function(List<SongFile>) tier) {
      if (remaining.isEmpty) return;
      final gs = tier(remaining);
      if (gs.isEmpty) return;
      final grouped = gs.expand((g) => g.songs.map((s) => s.path)).toSet();
      result.addAll(gs);
      remaining = remaining.where((s) => !grouped.contains(s.path)).toList();
    }

    // Tier 1: 粗分组
    takeTier((ss) => _coarseGroup(ss, durationToleranceMs));
    // Tier 2: 时长锚定（跨格式）
    takeTier(_durationAnchored);
    // Tier 3: 模糊匹配（分桶）
    takeTier((ss) => _fuzzyBucketed(ss, titleThreshold, durationToleranceMs));

    return {
      'groups': result.map((g) => g.toJson()).toList(),
      'remaining': remaining.map((s) => s.toJson()).toList(),
    };
  }

  /// 构造预计算的相似度键
  static _SimKey _simKeyOf(SongFile s) {
    final lt = (s.title.isNotEmpty ? s.title : s.displayName).toLowerCase();
    final ln = s.displayName.toLowerCase();
    final nt = _normText(s.title.isNotEmpty ? s.title : s.displayName);
    return _SimKey(
      path: s.path,
      durationMs: s.durationMs,
      normKey: _normalizeKey(s),
      normTitle: nt,
      lowerTitle: lt,
      lowerName: ln,
      artist: s.artist,
      normTitleBigrams: _bigrams(nt),
      titleBigrams: _bigrams(lt),
      nameBigrams: _bigrams(ln),
    );
  }

  static Set<String> _bigrams(String s) {
    final set = <String>{};
    for (var i = 0; i < s.length - 1; i++) {
      set.add(s.substring(i, i + 2));
    }
    return set;
  }

  // ---------- Tier 1: 粗分组 ----------
  //
  // 按归一化标题粗分组，桶内再按歌手兼容聚类（并查集）：同标题但
  // 歌手完全不同 → 不分组（宁可漏过）。歌手包含且人数差不大/笔误
  // 视为兼容；子集人数差 >= 2x 或 >= 3 人 → 不兼容，拆组。
  // 组 key 取首歌的 _normalizeKey（标题::歌手）+ 时长桶（2s 桶，
  // 与 Tier 2 同格式）：同标题不同时长的组 key 不能撞，否则
  // selections/忽略/缓存按 key 存取时会互相覆盖。
  static List<DuplicateGroup> _coarseGroup(
    List<SongFile> all,
    int durationToleranceMs,
  ) {
    // 先按归一化标题粗分组（去符号、去空格小写）
    final Map<String, List<SongFile>> coarse = {};
    for (final s in all) {
      final key = _normText(s.title.isNotEmpty ? s.title : s.displayName);
      // 空或单字 key 不参与粗分组，避免不同名歌曲因空串碰撞
      if (key.length < 2) continue;
      coarse.putIfAbsent(key, () => []).add(s);
    }

    final result = <DuplicateGroup>[];
    for (final entry in coarse.entries) {
      if (entry.value.length < 2) continue;
      // 歌手兼容聚类：同标题但歌手完全不同的歌分到不同簇
      final artistClusters = _clusterByArtistCompatible(entry.value);
      for (final cluster in artistClusters) {
        if (cluster.length < 2) continue;
        // 再按时长细拆：同标题同歌手但时长差 >2s 很可能不是同一首，拆成子组。
        // 同一录音转不同格式的时长差来自编码器填充，通常 <1s；Tier 2 也是 ±2s。
        // 曾用 durationToleranceMs*3（15s），「以太虚境++」（19.2s）与
        // 「以太虚境」（24.0s）差 4.8s 拆不开、合成一组导致错删整首。
        final subGroups = _splitByDuration(cluster, 2000);
        for (final g in subGroups) {
          if (g.length < 2) continue;
          final sorted = QualityService.sortByQualityDesc(g);
          result.add(
            DuplicateGroup(
              // key 带时长桶（与 Tier 2 同格式）：同标题不同时长的组
              // （如「以太虚境++」19.2s 与「以太虚境」24.0s）归一化
              // 标题相同，不带时长桶会撞 key，selections Map 里后一组
              // 覆盖前一组，以太虚境 6 首全变保留、总数还重复计数。
              // 桶宽 2000ms 与上方细拆容差一致，拆开的组桶一定不同。
              key:
                  '${_normalizeKey(sorted.first)}::${sorted.first.durationMs ~/ 2000}',
              songs: sorted,
              displayTitle: _displayTitle(sorted.first),
              reason: '标题/歌手一致',
            ),
          );
        }
      }
    }
    return result;
  }

  /// 按歌手兼容聚类（并查集）：兼容即同簇。空/未知歌手视为兼容，
  /// 无法判断时不拆（宁可漏过）。
  static List<List<SongFile>> _clusterByArtistCompatible(
    List<SongFile> songs,
  ) {
    final parent = <String, String>{for (final s in songs) s.path: s.path};
    String find(String x) {
      var r = x;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      var c = x;
      while (parent[c] != r) {
        final n = parent[c]!;
        parent[c] = r;
        c = n;
      }
      return r;
    }
    for (var i = 0; i < songs.length; i++) {
      for (var j = i + 1; j < songs.length; j++) {
        if (artistsCompatible(songs[i].artist, songs[j].artist)) {
          final ra = find(songs[i].path);
          final rb = find(songs[j].path);
          if (ra != rb) parent[ra] = rb;
        }
      }
    }
    final byRoot = <String, List<SongFile>>{};
    for (final s in songs) {
      byRoot.putIfAbsent(find(s.path), () => []).add(s);
    }
    return byRoot.values.toList();
  }

  // ---------- Tier 2: 时长锚定（跨格式/转码） ----------

  /// 同一首歌转成不同格式/码率后，标题可能略有差异、文件哈希完全不同，
  /// 但时长几乎不变（±2s 内）。按 2s 时长桶分组，桶内标题相近即判重复。
  ///
  /// 宁可漏过：只时长相同 → 不分组（防时长撞车）。还要求歌手兼容
  /// （同标题不同歌手是不同版本）+ 文件大小比合理（≤30x；WAV 对
  /// 低码率 MP3 约 22x，超过即异常，宁可漏过）。
  static List<DuplicateGroup> _durationAnchored(List<SongFile> songs) {
    const bucketMs = 2000;
    final buckets = <int, List<SongFile>>{};
    for (final s in songs) {
      buckets.putIfAbsent(s.durationMs ~/ bucketMs, () => []).add(s);
    }
    final keys = buckets.keys.toList()..sort();
    final result = <DuplicateGroup>[];
    final grouped = <String>{};

    for (var i = 0; i < keys.length; i++) {
      // 相似度键预计算一次：O(n²) 内层不再反复 normalize/分词
      final simKeys = <String, _SimKey>{};
      _SimKey kOf(SongFile s) =>
          simKeys.putIfAbsent(s.path, () => _simKeyOf(s));

      // 滑窗合并相邻桶，处理桶边界（1999ms 与 2001ms 本是同一首）
      final window = <SongFile>[];
      for (var k = i; k <= i + 1 && k < keys.length; k++) {
        if (keys[k] - keys[i] <= 1) window.addAll(buckets[keys[k]]!);
      }
      final local = window.where((s) => !grouped.contains(s.path)).toList();
      final visited = <String>{};
      for (var a = 0; a < local.length; a++) {
        if (visited.contains(local[a].path)) continue;
        final cur = <SongFile>[local[a]];
        visited.add(local[a].path);
        for (var b = a + 1; b < local.length; b++) {
          if (visited.contains(local[b].path)) continue;
          if ((local[a].durationMs - local[b].durationMs).abs() > bucketMs) {
            continue;
          }
          // 歌手完全不同 → 不同版本，不分组（宁可漏过）
          if (!artistsCompatible(local[a].artist, local[b].artist)) {
            continue;
          }
          // 文件大小比异常 → 不分组（同一录音转码的大小比有上限）
          if (!_sizeRatioPlausible(local[a], local[b])) {
            continue;
          }
          if (_sameSongLooseKey(kOf(local[a]), kOf(local[b]))) {
            cur.add(local[b]);
            visited.add(local[b].path);
          }
        }
        if (cur.length >= 2) {
          final sorted = QualityService.sortByQualityDesc(cur);
          result.add(
            DuplicateGroup(
              key:
                  'dur::${_normalizeKey(sorted.first)}::${sorted.first.durationMs ~/ bucketMs}',
              songs: sorted,
              displayTitle: _displayTitle(sorted.first),
              reason: '跨格式/转码重复',
            ),
          );
          grouped.addAll(cur.map((s) => s.path));
        }
      }
    }
    return result;
  }

  /// 判同：归一化 key 全等，或归一化标题相似度 ≥ 0.9。
  /// 调用方已保证两者时长在 ±2s 内。
  ///
  /// 注意：旧逻辑用原始标题相似度 ≥ 0.6，太松——"testsongA"/"testsongB"
  /// （不同音频、仅一字之差）bi-gram 相似度 0.875，会被误判为跨格式重复。
  /// 改用归一化标题（去括号/空格/符号，抓住"标题 (Remastered)"这类合法
  /// 差异）+ 0.9 阈值，一字之差的不同歌能被挡住。
  static bool _sameSongLooseKey(_SimKey a, _SimKey b) {
    if (a.normKey.length >= 2 && a.normKey == b.normKey) return true;
    if (a.normTitle.length < 2 || b.normTitle.length < 2) return false;
    return _simOf(
            a.normTitle, b.normTitle, a.normTitleBigrams, b.normTitleBigrams) >=
        0.9;
  }

  /// 文件大小比是否合理：同一录音转码后，大小比由码率比决定。
  /// WAV(1411kbps) 对 64kbps MP3 约 22x；超过 30x 即异常（如 100KB
  /// 对 50MB），宁可漏过。任一方大小未知（0）时无法判断，不拦截。
  static bool _sizeRatioPlausible(SongFile a, SongFile b) {
    if (a.sizeBytes <= 0 || b.sizeBytes <= 0) return true;
    final big = a.sizeBytes > b.sizeBytes ? a.sizeBytes : b.sizeBytes;
    final small = a.sizeBytes < b.sizeBytes ? a.sizeBytes : b.sizeBytes;
    return big / small <= 30;
  }

  // ---------- Tier 3: 模糊匹配（时长分桶） ----------

  /// 原来 leftovers > 800 就整个跳过模糊匹配（静默降级）。
  /// 改按 15s 时长分桶 + 滑窗，只在桶内两两比较：O(n²) → O(n·k)，
  /// 曲库再大也不用跳过。
  static List<DuplicateGroup> _fuzzyBucketed(
    List<SongFile> songs,
    double titleThreshold,
    int durationToleranceMs,
  ) {
    const bucketMs = 15000;
    final buckets = <int, List<SongFile>>{};
    for (final s in songs) {
      buckets.putIfAbsent(s.durationMs ~/ bucketMs, () => []).add(s);
    }
    final keys = buckets.keys.toList()..sort();
    final result = <DuplicateGroup>[];
    final visited = <String>{};

    for (var i = 0; i < keys.length; i++) {
      final window = <SongFile>[];
      for (var k = i; k <= i + 1 && k < keys.length; k++) {
        if (keys[k] - keys[i] <= 1) window.addAll(buckets[keys[k]]!);
      }
      final local = window.where((s) => !visited.contains(s.path)).toList();
      // 相似度键预计算一次：O(n²) 内层不再反复 toLowerCase/分词
      final simKeys = <String, _SimKey>{};
      _SimKey kOf(SongFile s) =>
          simKeys.putIfAbsent(s.path, () => _simKeyOf(s));

      for (var a = 0; a < local.length; a++) {
        final sa = local[a];
        if (visited.contains(sa.path)) continue;
        final cur = <SongFile>[sa];
        visited.add(sa.path);
        for (var b = a + 1; b < local.length; b++) {
          final sb = local[b];
          if (visited.contains(sb.path)) continue;
          if (_isSimilarKey(
              kOf(sa), kOf(sb), titleThreshold, durationToleranceMs)) {
            cur.add(sb);
            visited.add(sb.path);
          }
        }
        if (cur.length >= 2) {
          final sorted = QualityService.sortByQualityDesc(cur);
          result.add(
            DuplicateGroup(
              key: 'fuzzy::${_normalizeKey(sorted.first)}',
              songs: sorted,
              displayTitle: _displayTitle(sorted.first),
              reason: '标题相似+时长相近',
            ),
          );
        }
      }
    }
    // 注意：visited 包含所有被扫描过的单例，不能用它算 leftovers；
    // 外层 takeTier 会用各组的 songs 路径过滤，这里直接返回 groups 即可。
    return result;
  }

  // ---------- Tier 4: 文件内容哈希 ----------

  /// 文件名不同但字节内容相同的副本。哈希全等才算一组——
  /// 修掉了原来"取哈希前 12 字符近似"的错误逻辑（密码学哈希的前缀
  /// 不代表任何相似度，那样分组毫无意义）。
  static Future<List<DuplicateGroup>> _fileHashGroups(
    List<SongFile> songs,
    int durationToleranceMs,
    void Function(int done, int total)? onProgress,
  ) async {
    final cache = await FingerprintCache.load();
    final pool = HashWorkerPool();
    await pool.start();
    try {
      // 先查缓存：mtime 未变直接复用，不下发任务；
      // 已有指纹的（预设/缓存命中）跳过，避免被空结果覆盖
      final toHash = <SongFile>[];
      for (final s in songs) {
        if (s.fingerprint.isNotEmpty) continue;
        final hit = cache.lookup(s.path, s.dateModified);
        if (hit != null) {
          s.fingerprint = hit;
        } else {
          toHash.add(s);
        }
      }
      const batch = 50;
      var done = songs.length - toHash.length;
      final total = songs.length;
      onProgress?.call(done, total);
      for (var i = 0; i < toHash.length; i += batch) {
        final slice = toHash.sublist(i, min(i + batch, toHash.length));
        final fps = await Future.wait(
          slice.map(
            (s) => pool.hashFile(s.path, s.sizeBytes, s.extension),
          ),
        );
        for (var j = 0; j < slice.length; j++) {
          slice[j].fingerprint = fps[j];
          if (fps[j].isNotEmpty) {
            cache.store(slice[j].path, slice[j].dateModified, fps[j]);
          }
        }
        done += slice.length;
        onProgress?.call(done, total);
        // 让出 UI 线程，避免进度条卡死
        await Future.delayed(const Duration(milliseconds: 8));
      }
      await cache.save();

      final byHash = <String, List<SongFile>>{};
      for (final s in songs) {
        if (s.fingerprint.isEmpty) continue;
        byHash.putIfAbsent(s.fingerprint, () => []).add(s);
      }
      final result = <DuplicateGroup>[];
      for (final e in byHash.entries) {
        if (e.value.length < 2) continue;
        final sorted = QualityService.sortByQualityDesc(e.value);
        result.add(
          DuplicateGroup(
            key: 'hash::${e.key}',
            songs: sorted,
            displayTitle: _displayTitle(sorted.first),
            reason: '文件内容一致',
          ),
        );
      }
      debugPrint('[song_dedup] file-hash groups=${result.length}');
      return result;
    } finally {
      await pool.stop();
    }
  }

  // ---------- helpers ----------

  /// 归一化文本：小写、去括号内容、去符号空格，只留字母数字。
  /// "夜曲 (Live)"、"夜曲[Remastered]" 都会变成 "夜曲"。
  static String _normText(String input) {
    var x = input.toLowerCase().trim();
    // 去除括号内容： (Live), [Remastered] 等保留核心
    x = x.replaceAll(RegExp(r'\(.*?\)'), '');
    x = x.replaceAll(RegExp(r'\[.*?\]'), '');
    // 保留全部 Unicode 字母数字（中文/韩文/日文假名/字母）
    try {
      x = x.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    } catch (_) {
      // 兼容旧引擎：显式保留 中文/韩文/日文 区间
      x = x.replaceAll(
        RegExp(
          r'[^\w\u4e00-\u9fa5\u3040-\u309F\u30A0-\u30FF\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]',
        ),
        '',
      );
    }
    return x;
  }

  static String _normalizeKey(SongFile s) {
    final t = _normText(s.title.isNotEmpty ? s.title : s.displayName);
    final ar = _normText(s.artist);
    // 如果 artist 为 <unknown> 则只用 title
    if (ar.isEmpty || ar == 'unknown' || ar == 'unknownartist') {
      return t;
    }
    return '$t::$ar';
  }

  static String _displayTitle(SongFile s) {
    if (s.title.isNotEmpty && s.artist.isNotEmpty && s.artist != '<unknown>') {
      return '${s.artist} - ${s.title}';
    }
    return s.displayName;
  }

  static List<List<SongFile>> _splitByDuration(
    List<SongFile> list,
    int tolerance,
  ) {
    list.sort((a, b) => a.durationMs.compareTo(b.durationMs));
    final groups = <List<SongFile>>[];
    List<SongFile> cur = [list.first];
    for (int i = 1; i < list.length; i++) {
      if ((list[i].durationMs - cur.last.durationMs).abs() <= tolerance) {
        cur.add(list[i]);
      } else {
        groups.add(cur);
        cur = [list[i]];
      }
    }
    groups.add(cur);
    return groups;
  }

  static bool _isSimilarKey(
    _SimKey a,
    _SimKey b,
    double threshold,
    int durTol,
  ) {
    // 时长差异过大直接不算相似
    final durDiff = (a.durationMs - b.durationMs).abs();
    if (durDiff > durTol) return false;
    // 短歌的绝对容差太松：19.2s 与 24.0s 差 4.8s 是两首不同的歌
    // （以太虚境 vs 以太虚境++），不能只看绝对值；再加相对容差——
    // 时长差不得超过较长一方时长的 5%（下限 2s，兼容编码器填充的 1-2s
    // 偏差；长歌仍以 durTol 为上限，不收紧原有行为）。
    final longer = a.durationMs > b.durationMs ? a.durationMs : b.durationMs;
    final relTol = longer * 5 ~/ 100;
    if (durDiff > (relTol > 2000 ? relTol : 2000)) return false;

    // 歌手完全不同 → 不同版本，不分组（宁可漏过）
    if (!artistsCompatible(a.artist, b.artist)) return false;

    if (_simOf(a.lowerTitle, b.lowerTitle, a.titleBigrams, b.titleBigrams) >=
        threshold) {
      return true;
    }

    // 标题相似度不够，尝试文件名相似度兜底
    return _simOf(a.lowerName, b.lowerName, a.nameBigrams, b.nameBigrams) >=
        0.90;
  }

  /// 带预计算 bigram 的相似度：O(n²) 内层用此版本，避免反复分词
  static double _simOf(String a, String b, Set<String> bgA, Set<String> bgB) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (bgA.isEmpty || bgB.isEmpty) {
      // 退化为编辑距离
      return 1 - _levenshtein(a, b) / max(a.length, b.length);
    }
    final intersection = bgA.intersection(bgB).length;
    final dice = 2 * intersection / (bgA.length + bgB.length);
    // 对短标题加权编辑距离修正
    if (a.length < 6 || b.length < 6) {
      final lev = 1 - _levenshtein(a, b) / max(a.length, b.length);
      return max(dice, lev);
    }
    return dice;
  }

  static int _levenshtein(String s, String t) {
    final m = s.length, n = t.length;
    if (m == 0) return n;
    if (n == 0) return m;
    final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
    for (int i = 0; i <= m; i++) {
      dp[i][0] = i;
    }
    for (int j = 0; j <= n; j++) {
      dp[0][j] = j;
    }
    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        dp[i][j] = min(
          dp[i - 1][j] + 1,
          min(dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost),
        );
      }
    }
    return dp[m][n];
  }

  /// 同名声学细分阈值：3 段 chroma 余弦均值。
  /// 实测：同一录音转格式 = 1.0；不同歌曲 <= 0.972。取 0.99，
  /// 宁可把边界情况判为"不同版本"（不自动删，用户手动看）。
  static const double _chromaSameAudioThreshold = 0.99;

  // ---------- 组内元数据版本检测 ----------

  /// 文字脚本。kana/hangul 只在日/韩文出现，最具区分性；拉丁字母
  /// 在各语言元数据里都常见（艺人名/罗马音），优先级最低。
  static const _scriptPriority = ['kana', 'hangul', 'han', 'latin'];

  /// 版本关键词（按优先级排序，先匹配先赢）：
  /// 伴奏/听障类最具体；语言版次之；通用"版本"最后。
  /// ASCII 关键词用词边界正则，避免 "Instinct" 误含 "inst"。
  /// 和声伴奏是独立标签（不是伴奏的子类），排在伴奏之前；
  /// 子串消解（见 _versionTagInText）保证"和声伴奏"不被拆成"伴奏"。
  static final _versionKeywordPatterns = <(Pattern, String)>[
    // 和声伴奏（独立标签，优先于伴奏）
    ('和声伴奏', '和声伴奏'),
    (RegExp(r'\bharmony\b'), '和声伴奏'),
    ('和声', '和声伴奏'),
    // 伴奏
    ('伴奏', '伴奏'),
    (RegExp(r'\binstrumental\b'), '伴奏'),
    (RegExp(r'\boff vocal\b'), '伴奏'),
    (RegExp(r'\bkaraoke\b'), '伴奏'),
    (RegExp(r'\binst\b'), '伴奏'),
    // 听障
    ('听障', '听障'),
    ('低频', '听障'),
    (RegExp(r'\bhearing\b'), '听障'),
    // 合唱
    ('合唱', '合唱'),
    (RegExp(r'\bduet\b'), '合唱'),
    // 重制
    ('重制', '重制'),
    (RegExp(r'\bremaster(?:ed)?\b'), '重制'),
    // 现场版
    ('现场', '现场版'),
    (RegExp(r'\blive\b'), '现场版'),
    // 混音版
    ('混音', '混音版'),
    (RegExp(r'\bremix\b'), '混音版'),
    // 不插电
    ('不插电', '不插电'),
    (RegExp(r'\bacoustic\b'), '不插电'),
    (RegExp(r'\bunplugged\b'), '不插电'),
    // Demo
    (RegExp(r'\bdemo\b'), 'Demo'),
    // 语言版
    ('中文版', '中文版'),
    ('英文版', '英文版'),
    ('韩文版', '韩文版'),
    ('日文版', '日文版'),
    ('粤语版', '粤语版'),
    // 通用版本
    (RegExp(r'\bver\.'), '版本'),
    (RegExp(r'\bversion\b'), '版本'),
    ('版本', '版本'),
  ];

  /// 歌曲的主要文字脚本：统计标题+歌手的各脚本字符数，取最多者。
  /// 并列（无明显多数）时返回 'unknown'：无法确定，不拆组（宁可漏过，
  /// 证据不足不拆）。无脚本字符时返回 'unknown'。
  /// 先去掉括号内容（"夜曲 (Remastered)" 是中文歌，括号英文不算），
  /// displayName 兜底时先去扩展名（".flac" 里的拉丁字母不算）。
  /// 公开以便测试。
  static String dominantScriptOf(SongFile s) {
    var text = '${s.title} ${s.artist}';
    if (text.trim().isEmpty) {
      text = s.displayName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
    }
    // 去括号内容：(Live) / [Remastered] 等标注不是歌曲语言
    text = text.replaceAll(RegExp(r'\(.*?\)'), '');
    text = text.replaceAll(RegExp(r'\[.*?\]'), '');
    final counts = <String, int>{};
    for (final c in text.runes) {
      String? script;
      if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
        script = 'latin';
      } else if ((c >= 0xAC00 && c <= 0xD7AF) ||
          (c >= 0x1100 && c <= 0x11FF) ||
          (c >= 0x3130 && c <= 0x318F)) {
        script = 'hangul';
      } else if ((c >= 0x3040 && c <= 0x309F) ||
          (c >= 0x30A0 && c <= 0x30FF)) {
        script = 'kana';
      } else if (c >= 0x4E00 && c <= 0x9FFF) {
        script = 'han';
      }
      if (script != null) counts[script] = (counts[script] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'unknown';
    var best = '';
    var bestCount = -1;
    var tied = false;
    for (final script in _scriptPriority) {
      final n = counts[script] ?? 0;
      if (n > bestCount) {
        bestCount = n;
        best = script;
        tied = false;
      } else if (n == bestCount && n > 0) {
        tied = true;
      }
    }
    // 并列无明显多数 → 无法确定，返回 unknown（不拆组，宁可漏过）
    if (tied) return 'unknown';
    return best;
  }

  /// 版本标签：组合标签，多个标记用 + 连接，按优先级排序
  /// （Part > 年份 > 静态标签）。例如 "Part2+重制"、"2021年+伴奏"。
  /// 无标记 → '原版'。公开以便测试。
  static String versionTagOf(SongFile s) {
    // 逐字段检查：标题 → 文件名（去扩展名），首个命中为准
    for (final field in [
      s.title,
      s.displayName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
    ]) {
      final tag = _versionTagInText(field);
      if (tag != '原版') return tag;
    }
    return '原版';
  }

  /// 在单段文本里找版本标签（见 versionTagOf）。
  /// 标注 = 括号内容（"歌名 (Instrumental)"）、强分隔符后的尾部
  /// （"歌名 - 伴奏"）、最后一个词（"夜曲 低频听障版"）、中文关键词
  /// 后缀（"夜曲中文版"）。
  /// Part 编号（"Part.2"）与年份（"2021"）全文本扫描：Part.2/Part.3
  /// 是不同歌曲、(2021) 版是不同版本，必须区分。
  /// 歌名本身叫《Instrumental》/《伴奏》不误拆（关键词是整个标题，
  /// 前面无其他内容）；关键词在标题中间（"My Instrumental Song"）
  /// 也不认。
  static String _versionTagInText(String text) {
    // 先去下载副本后缀："歌名 (1)" / "歌名[2]" / "歌名（3）" 里的 (数字)
    // 是系统下载重命名后缀，不是版本标记。只去 1~2 位数字，避免误删
    // (2021) 这类年份标注；去完为空则整段无标签。
    var lower = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s*[\(\[（]\d{1,2}[\)\]）]\s*$'), '');
    final candidates = <String>{};

    // 1. 括号内容：(…)、[…]、【…】、（…）、〈…〉、『…』、「…」
    for (final m in RegExp(
      r'[\(\[\【\（\〈\『\「](.*?)[\)\]\】\）\〉\』\」]',
    ).allMatches(lower)) {
      _collectVersionTags(m.group(1) ?? '', candidates);
    }

    // 2. 强分隔符后的部分：取第一个分隔符之后的所有内容
    // （"A - B - 伴奏" → "B - 伴奏"，能抓到伴奏；"Artist - Title"
    // 里歌手部分的关键词不会漏进来）
    final sepMatch = RegExp(
      r'\s*-\s*|\s*–\s*|\s*—\s*|\s*\|\s*|\s*_\s*|\s*~\s*|::',
    ).firstMatch(lower);
    if (sepMatch != null) {
      _collectVersionTags(
        lower.substring(sepMatch.end),
        candidates,
      );
    }

    // 3. 最后一个词（前面须有其他词）："夜曲 低频听障版" → 听障
    final tokens =
        lower.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.length > 1) {
      _collectVersionTags(tokens.last, candidates);
    }

    // 4. 中文关键词后缀（前缀非空）："夜曲中文版" → 中文版；
    // "中文版" 本身 → 前缀为空 → 不认
    for (final (pattern, tag) in _versionKeywordPatterns) {
      if (pattern is! String) continue; // 只处理中文关键词
      if (lower.endsWith(pattern) && lower.length > pattern.length) {
        candidates.add(tag);
      }
    }

    // 5. Part 编号：全文本扫描（Part 在标题中间也认）
    final partTag = _extractPartTag(lower);
    if (partTag != null) candidates.add(partTag);

    // 6. 年份：全文本扫描
    final yearTag = _extractYearTag(lower);
    if (yearTag != null) candidates.add(yearTag);

    // 子串消解：和声伴奏 包含 伴奏，保留更具体的
    if (candidates.contains('和声伴奏')) candidates.remove('伴奏');

    if (candidates.isEmpty) return '原版';

    // 按优先级排序，组合返回
    final ordered = candidates.toList()
      ..sort((a, b) {
        final pa = _tagOrder(a);
        final pb = _tagOrder(b);
        if (pa != pb) return pa.compareTo(pb);
        return a.compareTo(b);
      });
    return ordered.join('+');
  }

  /// 提取 Part 编号：Part.2 / Part 2 / Pt.2 / Part2 / 第2部分 / 第2章。
  /// 返回 "Part2" 格式；无 Part 标记返回 null。公开以便测试。
  static String? _extractPartTag(String text) {
    final m = RegExp(
      r'\b(?:part|pt)\.?\s*(\d+)\b|第\s*(\d+)\s*(?:部分|章)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    final num = m.group(1) ?? m.group(2);
    if (num == null) return null;
    return 'Part$num';
  }

  /// 提取年份：(2021) / 2021版 / 标题里的 2021 → 返回 "2021年"。
  /// 只认 1900-2099 的 4 位年份。无年份返回 null。公开以便测试。
  static String? _extractYearTag(String text) {
    final m = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(text);
    if (m == null) return null;
    return '${m.group(0)}年';
  }

  /// 版本标签排序优先级：Part > 年份 > 静态标签
  /// （_versionKeywordPatterns 顺序，越前越高）。
  static int _tagOrder(String tag) {
    if (tag.startsWith('Part')) return -2;
    if (RegExp(r'^\d{4}年$').hasMatch(tag)) return -1;
    for (var i = 0; i < _versionKeywordPatterns.length; i++) {
      if (_versionKeywordPatterns[i].$2 == tag) return i;
    }
    return 999;
  }

  /// 在一段标注文本里收集命中的版本标签。
  static void _collectVersionTags(String segment, Set<String> out) {
    for (final (pattern, tag) in _versionKeywordPatterns) {
      if (pattern.allMatches(segment).isNotEmpty) out.add(tag);
    }
  }

  /// 歌手是否兼容：归一化后相等，或一方包含另一方且人数差不大，
  /// 或编辑距离在笔误容忍内（"周杰伦" vs "周杰轮" 是元数据笔误，不拆）。
  /// 任一方为空/未知/过短时无法判断，视为兼容，不拆。公开以便测试。
  ///
  /// 子集关系收紧：大集合人数 >= 小集合人数 × 2，或差 >= 3，视为不兼容。
  /// 例：Beethoven 9人版 vs 钢琴二人版（9 vs 1）→ 拆；
  /// 沉默是金 独唱 vs 合唱（1 vs 2）→ 拆；
  /// 周杰伦 vs 周杰伦&方文山（1 vs 2）→ 拆（多拆是漏过，安全）。
  static bool artistsCompatible(String a, String b) {
    final na = _normText(a);
    final nb = _normText(b);
    if (na.isEmpty || nb.isEmpty) return true;
    if (na == 'unknown' ||
        na == 'unknownartist' ||
        nb == 'unknown' ||
        nb == 'unknownartist') {
      return true;
    }
    if (na == nb) return true;
    if (na.length < 2 || nb.length < 2) return true;
    if (na.contains(nb) || nb.contains(na)) {
      // 子集关系：再看人数差
      final ca = _artistCount(a);
      final cb = _artistCount(b);
      final big = ca > cb ? ca : cb;
      final small = ca < cb ? ca : cb;
      if (big >= small * 2 || big - small >= 3) return false;
      return true;
    }
    // 笔误容忍：编辑距离 ≤ max(1, 短名长度/3)，但封顶 2 处。
    // 真笔误通常 1-2 字；容忍再大就会把不同歌手误判为同一人——
    // "Test Artist One" vs "Test Artist Two"（3 处不同）曾被误判兼容。
    // 宁可漏过：封顶后多处不同的名字一律视为不同歌手。
    final minLen = na.length < nb.length ? na.length : nb.length;
    var tol = minLen ~/ 3;
    if (tol < 1) tol = 1;
    if (tol > 2) tol = 2;
    return _editDistance(na, nb) <= tol;
  }

  /// 歌手人数：按分隔符拆分（& / 、 ， , ; ； + ／ / ・ 与）。
  /// feat. 后的歌手不计入（featCompatible 另行比对）。
  /// 无法拆分时返回 1。公开以便测试。
  static int _artistCount(String artist) {
    var text = artist;
    // 去掉 feat. 部分
    final featMatch = RegExp(
      r'\b(?:featuring|feat\.?|ft\.?)\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (featMatch != null) text = text.substring(0, featMatch.start);
    final parts = text
        .split(RegExp(r'[&\/、，,;；+／/・]|\band\b|与'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? 1 : parts.length;
  }

  /// Levenshtein 编辑距离（小串，O(m*n) 可接受）。
  static int _editDistance(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    var prev = List<int>.generate(n + 1, (j) => j);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var best = prev[j] + 1;
        if (cur[j - 1] + 1 < best) best = cur[j - 1] + 1;
        if (prev[j - 1] + cost < best) best = prev[j - 1] + cost;
        cur[j] = best;
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[n];
  }

  /// feat. 歌手集合：从标题/歌手/文件名提取 feat./featuring/ft. 后的歌手名。
  /// 格式多样：`feat. A`、`featuring A`、`ft. A`、`(feat. A)`、`feat A`、
  /// 多人用 &/、/，/与/and 分隔（`feat. A & B`）。
  /// 逐字段查找（标题 → 歌手 → 文件名），首个含 feat. 的字段为准；
  /// 返回归一化后的名字集合；无 feat. 信息时返回空集合。
  /// 公开以便测试。
  static Set<String> featArtistsOf(SongFile s) {
    final fields = [
      s.title,
      s.artist,
      s.displayName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
    ];
    for (final field in fields) {
      final found = _featArtistsInText(field);
      if (found.isNotEmpty) return found;
    }
    return {};
  }

  /// 从单段文本提取 feat. 后的歌手名集合。
  static Set<String> _featArtistsInText(String text) {
    final m = RegExp(
      r'\b(?:featuring|feat\.?|ft\.?)\b\s*[:：]?\s*',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return {};
    var rest = text.substring(m.end);
    // 截断：右括号/分隔符/新括号标注都表示 feat. 部分结束
    final cut = RegExp(r'[\)\]\}\|\n]|\(|\[| - | – | — ').firstMatch(rest);
    if (cut != null) rest = rest.substring(0, cut.start);
    final out = <String>{};
    for (final part in rest.split(
      RegExp(r'[&、，,;；+／/・]|\band\b|与'),
    )) {
      final name = _normText(part);
      if (name.isNotEmpty) out.add(name);
    }
    return out;
  }

  /// feat. 是否兼容：都无 feat. → 兼容；一方有、一方无 → 不兼容；
  /// 都有 → 集合相等才兼容。公开以便测试。
  static bool featCompatible(SongFile a, SongFile b) {
    final fa = featArtistsOf(a);
    final fb = featArtistsOf(b);
    if (fa.isEmpty && fb.isEmpty) return true;
    if (fa.isEmpty || fb.isEmpty) return false;
    return fa.length == fb.length && fa.containsAll(fb);
  }

  /// 元数据兼容：脚本、版本标签、歌手、feat. 四项都兼容才算兼容，任一不同即拆组。
  /// 脚本 unknown（无脚本字符）视为通配，不拆。
  static bool _metadataCompatible(SongFile a, SongFile b) {
    final sa = dominantScriptOf(a);
    final sb = dominantScriptOf(b);
    if (sa != 'unknown' && sb != 'unknown' && sa != sb) return false;
    if (versionTagOf(a) != versionTagOf(b)) return false;
    if (!artistsCompatible(a.artist, b.artist)) return false;
    if (!featCompatible(a, b)) return false;
    return true;
  }

  /// 组内按元数据聚类：单链（兼容即同簇）。公开以便测试。
  static List<List<SongFile>> clusterByMetadata(List<SongFile> songs) {
    final parent = <String, String>{for (final s in songs) s.path: s.path};
    String find(String x) {
      var r = x;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      var c = x;
      while (parent[c] != r) {
        final n = parent[c]!;
        parent[c] = r;
        c = n;
      }
      return r;
    }

    for (var i = 0; i < songs.length; i++) {
      for (var j = i + 1; j < songs.length; j++) {
        if (_metadataCompatible(songs[i], songs[j])) {
          final ra = find(songs[i].path);
          final rb = find(songs[j].path);
          if (ra != rb) parent[ra] = rb;
        }
      }
    }
    final byRoot = <String, List<SongFile>>{};
    for (final s in songs) {
      byRoot.putIfAbsent(find(s.path), () => []).add(s);
    }
    return byRoot.values.toList();
  }

  /// 对所有组做元数据细分：最大簇保留原组，其余拆成
  /// reason='同名不同版本'、noAutoSelect=true 的新组。
  /// 只保留长度 >= 2 的簇：单首簇丢弃，全是单首簇时整组丢弃。
  /// 公开以便测试。纯字符串比对，不走开关，每次扫描都做。
  static List<DuplicateGroup> subdivideByMetadata(List<DuplicateGroup> groups) {
    final out = <DuplicateGroup>[];
    for (final g in groups) {
      if (g.songs.length < 2) {
        // 单首歌不是重复组，直接丢弃
        continue;
      }
      final clusters = clusterByMetadata(g.songs);
      if (clusters.length <= 1) {
        out.add(g);
        continue;
      }
      clusters.sort((a, b) => b.length.compareTo(a.length));
      // 只保留 >= 2 的簇，单首簇丢弃
      final valid = clusters.where((c) => c.length >= 2).toList();
      if (valid.isEmpty) {
        debugPrint('[song_dedup] metadata subdivided "${g.displayTitle}": '
            'all singletons, group dropped');
        continue;
      }
      out.add(DuplicateGroup(
        key: g.key,
        songs: QualityService.sortByQualityDesc(valid.first),
        displayTitle: g.displayTitle,
        reason: g.reason,
      ));
      for (var i = 1; i < valid.length; i++) {
        out.add(DuplicateGroup(
          key: '${g.key}::meta$i',
          songs: QualityService.sortByQualityDesc(valid[i]),
          displayTitle: g.displayTitle,
          reason: '同名不同版本',
          noAutoSelect: true,
        ));
      }
      debugPrint('[song_dedup] metadata subdivided "${g.displayTitle}": '
          '${clusters.map((c) => c.length).toList()}');
    }
    return out;
  }

  /// 对 Tier 1（标题/歌手一致）组做 chroma 细分。
  /// 同一录音的保留原组；不同版本拆成新组（reason='同名不同版本'，
  /// noAutoSelect=true）。指纹按 path+mtime 缓存，3 路并行计算。
  static Future<List<DuplicateGroup>> _subdivideTitleGroupsByChroma(
    List<DuplicateGroup> groups, {
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = <SongFile>[];
    for (final g in groups) {
      if (g.reason == '标题/歌手一致' && g.songs.length >= 2) {
        targets.addAll(g.songs);
      }
    }
    if (targets.length < 2) return groups;

    final cache = await ChromaFpCache.load();
    final fps = <String, List<double>>{};
    final toCompute = <SongFile>[];
    for (final s in targets) {
      final hit = cache.lookup(s.path, s.dateModified);
      if (hit != null) {
        fps[s.path] = hit;
      } else {
        toCompute.add(s);
      }
    }
    var done = targets.length - toCompute.length;
    onProgress?.call(done, targets.length);

    var dirty = false;
    await _parallel(toCompute, 3, (s) async {
      List<double>? fp;
      try {
        fp = await ChromaFingerprintService.getChroma(s.id, s.path).timeout(
            const Duration(seconds: 60), onTimeout: () => null);
      } catch (_) {
        fp = null;
      }
      if (fp != null) {
        cache.store(s.path, s.dateModified, fp);
        dirty = true;
        fps[s.path] = fp;
      }
      done++;
      onProgress?.call(done, targets.length);
    });
    if (dirty) await cache.save();

    final out = <DuplicateGroup>[];
    for (final g in groups) {
      if (g.reason != '标题/歌手一致' || g.songs.length < 2) {
        out.add(g);
        continue;
      }
      final clusters = clusterByChroma(g.songs, fps);
      if (clusters.length <= 1) {
        out.add(g);
        continue;
      }
      clusters.sort((a, b) => b.length.compareTo(a.length));
      // 只保留 >= 2 的簇，单首簇丢弃；全是单首簇时整组丢弃
      final valid = clusters.where((c) => c.length >= 2).toList();
      if (valid.isEmpty) {
        debugPrint('[song_dedup] chroma subdivided "${g.displayTitle}": '
            'all singletons, group dropped');
        continue;
      }
      out.add(DuplicateGroup(
        key: g.key,
        songs: QualityService.sortByQualityDesc(valid.first),
        displayTitle: g.displayTitle,
        reason: g.reason,
      ));
      for (var i = 1; i < valid.length; i++) {
        out.add(DuplicateGroup(
          key: '${g.key}::ver$i',
          songs: QualityService.sortByQualityDesc(valid[i]),
          displayTitle: g.displayTitle,
          reason: '同名不同版本',
          noAutoSelect: true,
        ));
      }
      debugPrint('[song_dedup] chroma subdivided "${g.displayTitle}": '
          '${clusters.map((c) => c.length).toList()}');
    }
    return out;
  }

  /// 单链聚类：两两 chroma 相似度 >= 阈值则同簇。
  /// 指纹缺失的歌曲并入最大簇（无法判断时保守处理，不单独成组）。
  static List<List<SongFile>> clusterByChroma(
      List<SongFile> songs, Map<String, List<double>> fps) {
    final parent = <String, String>{for (final s in songs) s.path: s.path};
    String find(String x) {
      var r = x;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      var c = x;
      while (parent[c] != r) {
        final n = parent[c]!;
        parent[c] = r;
        c = n;
      }
      return r;
    }

    for (var i = 0; i < songs.length; i++) {
      final a = fps[songs[i].path];
      if (a == null) continue;
      for (var j = i + 1; j < songs.length; j++) {
        final b = fps[songs[j].path];
        if (b == null) continue;
        if (ChromaFingerprintService.similarity(a, b) >=
            _chromaSameAudioThreshold) {
          final ra = find(songs[i].path);
          final rb = find(songs[j].path);
          if (ra != rb) parent[ra] = rb;
        }
      }
    }
    final byRoot = <String, List<SongFile>>{};
    for (final s in songs) {
      byRoot.putIfAbsent(find(s.path), () => []).add(s);
    }
    final clusters = byRoot.values.toList();
    if (clusters.length <= 1) return clusters;
    clusters.sort((a, b) => b.length.compareTo(a.length));
    final main = clusters.first;
    final rest = <List<SongFile>>[];
    for (var i = 1; i < clusters.length; i++) {
      final missing =
          clusters[i].where((s) => !fps.containsKey(s.path)).toList();
      final kept = clusters[i].where((s) => fps.containsKey(s.path)).toList();
      main.addAll(missing);
      if (kept.isNotEmpty) rest.add(kept);
    }
    return [main, ...rest];
  }

  /// 简单并行：concurrency 个 worker 消费队列。
  /// Dart 单线程，取任务与自增之间无 await，原子安全。
  static Future<void> _parallel<T>(
      List<T> items, int concurrency, Future<void> Function(T) fn) async {
    if (items.isEmpty) return;
    var idx = 0;
    Future<void> worker() async {
      while (true) {
        if (idx >= items.length) {
          return;
        }
        final item = items[idx++];
        await fn(item);
      }
    }
    await Future.wait(List.generate(concurrency, (_) => worker()));
  }
}
