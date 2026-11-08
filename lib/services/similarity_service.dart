import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/duplicate_group.dart';
import '../models/song_file.dart';
import 'fingerprint_cache.dart';
import 'isolate_pool.dart';
import 'quality_service.dart';

class SimilarityService {
  /// 主入口：四层递进，每层只处理上层剩下的歌曲。
  ///
  /// 1. 粗分组：标题/歌手归一化全等（最常见：同标题同歌手多版本）
  /// 2. 时长锚定：同时长（±2s）+ 标题相近 → 跨格式/转码副本。
  ///    时长与编码格式无关，是跨格式识别最可靠的信号。
  /// 3. 模糊匹配：标题相似度 + 时长相近。按时长分桶比较，
  ///    不再因曲库大而静默跳过。
  /// 4. 文件内容哈希全等：字节级相同的副本（文件名不同也认得）。
  ///    注意这是字节哈希不是声学指纹，转码过的认不出——那是第 2 层的事。
  static Future<List<DuplicateGroup>> groupSimilarSongsWithFingerprint(
    List<SongFile> all, {
    double titleThreshold = 0.85,
    int durationToleranceMs = 5000,
    bool enableFingerprint = true,
    void Function(int done, int total)? onProgress,
  }) async {
    if (all.isEmpty) return [];
    final result = <DuplicateGroup>[];
    var remaining = List<SongFile>.from(all);

    void takeTier(List<DuplicateGroup> Function(List<SongFile>) tier) {
      if (remaining.isEmpty) return;
      final gs = tier(remaining);
      if (gs.isEmpty) return;
      final grouped = gs.expand((g) => g.songs.map((s) => s.path)).toSet();
      result.addAll(gs);
      remaining = remaining.where((s) => !grouped.contains(s.path)).toList();
    }

    // Tier 1: 粗分组
    takeTier((songs) => _coarseGroup(songs, durationToleranceMs));
    // Tier 2: 时长锚定（跨格式）
    takeTier(_durationAnchored);
    // Tier 3: 模糊匹配（分桶）
    takeTier(
      (songs) => _fuzzyBucketed(songs, titleThreshold, durationToleranceMs),
    );

    // Tier 4: 文件内容哈希（可开关，IO 开销大）
    if (enableFingerprint && remaining.length >= 2) {
      final gs = await _fileHashGroups(
        remaining,
        durationToleranceMs,
        onProgress,
      );
      result.addAll(gs);
    }

    // 按组大小排序：大组优先
    result.sort((a, b) => b.songs.length.compareTo(a.songs.length));
    return result;
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
          if (_sameSongLoose(local[a], local[b])) {
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

  /// 宽松判同：归一化 key 全等，或标题相似度 ≥ 0.6。
  /// 调用方已保证两者时长在 ±2s 内——不同歌极少同时满足这两个条件。
  static bool _sameSongLoose(SongFile a, SongFile b) {
    final ka = _normalizeKey(a);
    if (ka.length >= 2 && ka == _normalizeKey(b)) return true;
    final ta = (a.title.isNotEmpty ? a.title : a.displayName).toLowerCase();
    final tb = (b.title.isNotEmpty ? b.title : b.displayName).toLowerCase();
    return _stringSimilarity(ta, tb) >= 0.6;
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
      for (var a = 0; a < local.length; a++) {
        final sa = local[a];
        if (visited.contains(sa.path)) continue;
        final cur = <SongFile>[sa];
        visited.add(sa.path);
        for (var b = a + 1; b < local.length; b++) {
          final sb = local[b];
          if (visited.contains(sb.path)) continue;
          if (_isSimilar(sa, sb, titleThreshold, durationToleranceMs)) {
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
        final hit = cache.lookup(s.path);
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
          if (fps[j].isNotEmpty) cache.store(slice[j].path, fps[j]);
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

  static String _normalizeKey(SongFile s) {
    String norm(String input) {
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

    final t = norm(s.title.isNotEmpty ? s.title : s.displayName);
    final ar = norm(s.artist);
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

  static bool _isSimilar(
    SongFile a,
    SongFile b,
    double threshold,
    int durTol,
  ) {
    // 时长差异过大直接不算相似
    if ((a.durationMs - b.durationMs).abs() > durTol) return false;

    final ta = a.title.isNotEmpty ? a.title : a.displayName;
    final tb = b.title.isNotEmpty ? b.title : b.displayName;
    final sim = _stringSimilarity(ta.toLowerCase(), tb.toLowerCase());
    if (sim >= threshold) return true;

    // 标题相似度不够，尝试文件名相似度兜底
    final fa = a.displayName.toLowerCase();
    final fb = b.displayName.toLowerCase();
    return _stringSimilarity(fa, fb) >= 0.90;
  }

  /// bi-gram Dice，短标题用编辑距离修正
  static double _stringSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;

    Set<String> bigrams(String s) {
      final set = <String>{};
      for (int i = 0; i < s.length - 1; i++) {
        set.add(s.substring(i, i + 2));
      }
      return set;
    }

    final bgA = bigrams(a);
    final bgB = bigrams(b);
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
}
