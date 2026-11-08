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
    required this.normTitleBigrams,
    required this.titleBigrams,
    required this.nameBigrams,
  });
}

class SimilarityService {
  /// 主入口：四层递进，每层只处理上层剩下的歌曲。
  ///
  /// 1. 粗分组：标题/歌手归一化全等（最常见：同标题同歌手多版本）
  /// 2. 时长锚定：同时长（±2s）+ 标题相近（归一化标题相似度 ≥0.9）
  ///    → 跨格式/转码副本。时长与编码格式无关，是跨格式识别最可靠的信号。
  /// 3. 模糊匹配：标题相似度（≥0.9）+ 时长相近。按时长分桶比较，
  ///    不再因曲库大而静默跳过。
  /// 4. 文件内容哈希全等：字节级相同的副本（文件名不同也认得）。
  ///    注意这是字节哈希不是声学指纹，转码过的认不出——那是第 2 层的事。
  static Future<List<DuplicateGroup>> groupSimilarSongsWithFingerprint(
    List<SongFile> all, {
    double titleThreshold = 0.9,
    int durationToleranceMs = 5000,
    bool enableFingerprint = true,
    bool enableCrossLingual = false,
    void Function(int done, int total)? onProgress,
    void Function(int done, int total)? onChromaProgress,
    void Function(int done, int total)? onCrossLingualProgress,
  }) async {
    if (all.isEmpty) return [];
    // Tier 1~3：同步 CPU 密集计算（O(n²) 字符串比对），在后台 isolate
    // 执行，避免大曲库卡住 UI 线程导致界面冻结/ANR。
    // isolate 消息不支持自定义对象，边界处用 JSON 序列化。
    final songsJson = all.map((s) => s.toJson()).toList();
    final syncOut = await Isolate.run<Map<String, dynamic>>(
      () => _syncTiersJson(<String, dynamic>{
        'songs': songsJson,
        'durationToleranceMs': durationToleranceMs,
        'titleThreshold': titleThreshold,
      }),
    );
    var result = (syncOut['groups'] as List)
        .map((e) => DuplicateGroup.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    var remaining = (syncOut['remaining'] as List)
        .map((e) => SongFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    // 同名组声学细分：同一标题/歌手下，用 chroma 指纹区分同一录音与不同版本。
    // 只对 Tier 1（标题/歌手一致）组做，不同版本拆出且不自动勾选。
    result = await _subdivideTitleGroupsByChroma(result, onProgress: onChromaProgress);

    // Tier 4: 文件内容哈希（可开关，IO 开销大）
    if (enableFingerprint && remaining.length >= 2) {
      final gs = await _fileHashGroups(
        remaining,
        durationToleranceMs,
        onProgress,
      );
      final grouped = gs.expand((g) => g.songs.map((s) => s.path)).toSet();
      result.addAll(gs);
      remaining = remaining.where((s) => !grouped.contains(s.path)).toList();
    }

    // 跨语言版本检测：在未分组歌曲中找时长接近 + chroma 高度相似的对
    // （伴奏一致、语言不同，如中/英文版）。只对 remaining 做，不打乱已有分组。
    // 结果 reason='跨语言版本'，noAutoSelect=true，默认不勾选。
    // 默认关闭（设置页可开）：chroma 计算重，首扫慢。
    if (enableCrossLingual && remaining.length >= 2) {
      final gs = await _findCrossLingualGroups(
        remaining,
        onProgress: onCrossLingualProgress,
      );
      final grouped = gs.expand((g) => g.songs.map((s) => s.path)).toSet();
      result.addAll(gs);
      remaining = remaining.where((s) => !grouped.contains(s.path)).toList();
    }

    // 按组大小排序：大组优先
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

  static List<DuplicateGroup> _coarseGroup(
    List<SongFile> all,
    int durationToleranceMs,
  ) {
    // 先按 normalizedKey 粗分组（去符号、去空格小写）
    final Map<String, List<SongFile>> coarse = {};
    for (final s in all) {
      final key = _normalizeKey(s);
      // 空或单字 key 不参与粗分组，避免不同名歌曲因空串碰撞
      if (key.length < 2) continue;
      coarse.putIfAbsent(key, () => []).add(s);
    }

    final result = <DuplicateGroup>[];
    for (final entry in coarse.entries) {
      if (entry.value.length < 2) continue;
      // 再按时长细拆：时长差异过大(>15秒)可能不是同一首，拆成子组
      final subGroups = _splitByDuration(entry.value, durationToleranceMs * 3);
      for (final g in subGroups) {
        if (g.length < 2) continue;
        final sorted = QualityService.sortByQualityDesc(g);
        result.add(
          DuplicateGroup(
            key: entry.key,
            songs: sorted,
            displayTitle: _displayTitle(sorted.first),
            reason: '标题/歌手一致',
          ),
        );
      }
    }
    return result;
  }

  // ---------- Tier 2: 时长锚定（跨格式/转码） ----------

  /// 同一首歌转成不同格式/码率后，标题可能略有差异、文件哈希完全不同，
  /// 但时长几乎不变（±2s 内）。按 2s 时长桶分组，桶内标题相近即判重复。
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
            (s) => pool.hashFile(s.path, s.sizeBytes, s.durationMs, s.extension),
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
    if ((a.durationMs - b.durationMs).abs() > durTol) return false;

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
      out.add(DuplicateGroup(
        key: g.key,
        songs: QualityService.sortByQualityDesc(clusters.first),
        displayTitle: g.displayTitle,
        reason: g.reason,
      ));
      for (var i = 1; i < clusters.length; i++) {
        out.add(DuplicateGroup(
          key: '${g.key}::ver$i',
          songs: QualityService.sortByQualityDesc(clusters[i]),
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

  /// 跨语言版本检测阈值：3 段 chroma 余弦均值。
  /// 实测：星间旅行中/英文版（同伴奏）= 0.9937；不同歌曲 <= 0.972。
  /// 取 0.985，只抓伴奏高度一致的；分组默认不自动勾选，误判用户手动忽略。
  static const double chromaCrossLingualThreshold = 0.985;

  /// 跨语言版本检测：在未分组歌曲中，找时长接近（<= min(2%, 5000ms)）
  /// 且 chroma 相似度 >= 0.985 的对，单链聚类成组。
  /// 只比较时长候选对，不做全量 O(n^2) 声学比对。
  static Future<List<DuplicateGroup>> _findCrossLingualGroups(
    List<SongFile> remaining, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (remaining.length < 2) return [];

    // 1. 按时长排序，滑动窗口找候选对
    final sorted = List<SongFile>.from(remaining)
      ..sort((a, b) => a.durationMs.compareTo(b.durationMs));
    final candidatePairs = <List<SongFile>>[];
    final inCandidate = <String>{};
    for (var i = 0; i < sorted.length; i++) {
      for (var j = i + 1; j < sorted.length; j++) {
        final dd = sorted[j].durationMs - sorted[i].durationMs;
        final tol =
            min(3000, (sorted[i].durationMs * 0.01).round()).toInt();
        if (dd > tol) break;
        candidatePairs.add([sorted[i], sorted[j]]);
        inCandidate.add(sorted[i].path);
        inCandidate.add(sorted[j].path);
      }
    }
    if (candidatePairs.isEmpty) return [];

    // 2. 计算候选歌曲的 chroma 指纹（缓存 + 3 路并行）
    final cache = await ChromaFpCache.load();
    final fps = <String, List<double>>{};
    final toCompute = <SongFile>[];
    for (final s in sorted) {
      if (!inCandidate.contains(s.path)) continue;
      final hit = cache.lookup(s.path, s.dateModified);
      if (hit != null) {
        fps[s.path] = hit;
      } else {
        toCompute.add(s);
      }
    }
    var done = inCandidate.length - toCompute.length;
    onProgress?.call(done, inCandidate.length);
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
      onProgress?.call(done, inCandidate.length);
    });
    if (dirty) await cache.save();

    // 3. 候选对连边（相似度 >= 阈值），并查集聚类
    final parent = <String, String>{for (final p in inCandidate) p: p};
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

    for (final pair in candidatePairs) {
      final a = fps[pair[0].path];
      final b = fps[pair[1].path];
      if (a == null || b == null) continue;
      if (ChromaFingerprintService.similarity(a, b) >=
          chromaCrossLingualThreshold) {
        final ra = find(pair[0].path);
        final rb = find(pair[1].path);
        if (ra != rb) parent[ra] = rb;
      }
    }

    final byRoot = <String, List<SongFile>>{};
    final byPath = {for (final x in sorted) x.path: x};
    for (final p in inCandidate) {
      final song = byPath[p];
      if (song == null) continue;
      // 指纹缺失的跳过（无法判断，不硬分组）
      if (!fps.containsKey(p)) continue;
      byRoot.putIfAbsent(find(p), () => []).add(song);
    }

    // 4. 成组
    final out = <DuplicateGroup>[];
    var idx = 0;
    for (final cluster in byRoot.values) {
      if (cluster.length < 2) continue;
      final ordered = QualityService.sortByQualityDesc(cluster);
      out.add(DuplicateGroup(
        key: 'crosslingual::$idx:${ordered.map((e) => e.path).join('|')}',
        songs: ordered,
        displayTitle: ordered.first.displayName,
        reason: '跨语言版本',
        noAutoSelect: true,
      ));
      idx++;
      debugPrint('[song_dedup] cross-lingual group: '
          '${ordered.map((e) => e.displayName).join(' / ')}');
    }
    return out;
  }
}
