import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/isolate_pool.dart';
import 'package:song_dedup/services/similarity_service.dart';

SongFile mk({
  required String path,
  String title = '',
  String artist = '',
  int durationMs = 0,
  int sizeBytes = 1000000,
  String ext = 'mp3',
  String? fingerprint,
}) {
  final name = path.split('/').last;
  return SongFile(
    id: 0,
    path: path,
    displayName: name,
    title: title,
    artist: artist,
    album: '',
    durationMs: durationMs,
    sizeBytes: sizeBytes,
    extension: ext,
    fingerprint: fingerprint,
  );
}

void main() {
  group('Tier1 粗分组', () {
    test('同标题同歌手不同格式 → 一组', () async {
      final songs = [
        mk(path: '/a/夜曲.flac', title: '夜曲', artist: '周杰伦', durationMs: 210000, ext: 'flac', sizeBytes: 30000000),
        mk(path: '/a/夜曲.mp3', title: '夜曲', artist: '周杰伦', durationMs: 211000, ext: 'mp3', sizeBytes: 8000000),
        mk(path: '/a/晴天.mp3', title: '晴天', artist: '周杰伦', durationMs: 260000, ext: 'mp3'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs.length, 1);
      expect(gs.first.songs.length, 2);
      expect(gs.first.reason, '标题/歌手一致');
      // flac 音质分更高，应排第一（保留）
      expect(gs.first.best.extension, 'flac');
    });

    test('时长差 >15s 的同名歌曲不合并（不同版本）', () async {
      final songs = [
        mk(path: '/a/夜曲.mp3', title: '夜曲', artist: '周杰伦', durationMs: 210000),
        mk(path: '/a/夜曲live.mp3', title: '夜曲', artist: '周杰伦', durationMs: 260000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });

    test('同标题归一化后相同、时长差 4.8s → 拆成两组（以太虚境回归）', () async {
      // 回归：Tier 1 时长细拆阈值曾为 15s，「以太虚境++」（19.2s）与
      // 「以太虚境」（24.0s）归一化后标题相同、差 4.8s，拆不开合成一组，
      // 10 首被自动勾选，删了会丢整首以太虚境。
      final songs = [
        mk(path: '/a/以太虚境++.flac', title: '以太虚境++', artist: '三Z-STUDIO&HOYO-MiX', durationMs: 19200, ext: 'flac'),
        mk(path: '/a/以太虚境++ (1).flac', title: '以太虚境++', artist: '三Z-STUDIO&HOYO-MiX', durationMs: 19200, ext: 'flac'),
        mk(path: '/a/以太虚境.flac', title: '以太虚境', artist: '三Z-STUDIO&HOYO-MiX', durationMs: 24000, ext: 'flac'),
        mk(path: '/a/以太虚境 (1).flac', title: '以太虚境', artist: '三Z-STUDIO&HOYO-MiX', durationMs: 24000, ext: 'flac'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs.length, 2);
      expect(gs.every((g) => g.songs.length == 2), isTrue);
      // 两组 key 必须不同：归一化标题相同（++ 被去掉），不带时长桶会
      // 撞 key，selections Map 里后一组覆盖前一组。
      expect(gs[0].key != gs[1].key, isTrue);
    });

    test('单首以太虚境++（19.2s）与以太虚境（24.0s）→ Tier 3 也不分组', () async {
      // 回归：副本删光只剩单首后，Tier 1 不成组，两首落到 Tier 3；
      // Tier 3 只看绝对容差 ±5s，4.8s 差又把两首不同的歌合成一组，
      // 会错删整首以太虚境。相对容差（较长一方 5%，下限 2s）应挡住。
      final songs = [
        mk(path: '/a/以太虚境++.flac', title: '以太虚境++', artist: '三Z-STUDIO&HOYO-MiX', durationMs: 19200, ext: 'flac'),
        mk(path: '/a/以太虚境.flac', title: '以太虚境', artist: '三Z-STUDIO&HOYO-MiX', durationMs: 24000, ext: 'flac'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });
  });

  group('Tier2 时长锚定（跨格式）', () {
    test('一字之差的不同音频+同时长 → 不误判（回归）', () async {
      // testsongA(440Hz)/testsongB(880Hz) 是不同音频，仅一字之差。
      // 旧逻辑标题相似度阈值 0.6（两者 0.875）会误判为跨格式重复；
      // 收紧到归一化标题 ≥0.9 后，Tier2 与 Tier3 都不应收录。
      final songs = [
        mk(path: '/a/testsongA.wav', title: 'testsongA', durationMs: 35000, ext: 'wav', sizeBytes: 560000),
        mk(path: '/a/testsongB.mp3', title: 'testsongB', durationMs: 35000, ext: 'mp3', sizeBytes: 800000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });

    test('同歌+歌手元数据笔误 → Tier1 一组（歌手兼容）', () async {
      // 同一首歌歌手写错一字：归一化 key 不等，但歌手兼容
      // （笔误容忍），Tier1 按标题+歌手兼容分组
      final songs = [
        mk(path: '/a/夜曲.flac', title: '夜曲', artist: '周杰伦', durationMs: 210000, ext: 'flac', sizeBytes: 30000000),
        mk(path: '/a/夜曲.mp3', title: '夜曲', artist: '周杰轮', durationMs: 210500, ext: 'mp3', sizeBytes: 8000000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs.length, 1);
      expect(gs.first.reason, '标题/歌手一致');
    });

    test('同标题歌手完全不同 → 不分组（宁可漏过）', () async {
      // WHITE NIGHT 英文版 vs 中文版：标题相同、时长相同，但歌手
      // 完全不同，Tier1/2/3 都不应收录
      final songs = [
        mk(path: '/a/white_night_kr.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX', durationMs: 200000, ext: 'flac', sizeBytes: 30000000),
        mk(path: '/a/white_night_cn.flac', title: 'WHITE NIGHT', artist: '西山晃世&HOYO-MiX', durationMs: 200500, ext: 'flac', sizeBytes: 29000000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });

    test('只时长相同+标题不同 → 不分组（防时长撞车）', () async {
      // 两首完全不同的歌恰好同时长：标题不同、歌手不同，
      // 只时长相同不能分组
      final songs = [
        mk(path: '/a/song_a.mp3', title: 'aaaa bbbb', artist: '歌手甲', durationMs: 200000, ext: 'mp3', sizeBytes: 5000000),
        mk(path: '/a/song_b.mp3', title: 'cccc dddd', artist: '歌手乙', durationMs: 200000, ext: 'mp3', sizeBytes: 5200000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });

    test('Tier2 大小比异常 → 不分组（标题只差一字）', () async {
      // 标题只差一字（normTitle 相似度 ~0.97 ≥ 0.9），走 Tier2；
      // 用 titleThreshold 0.99 屏蔽 Tier3（其 lowerTitle 相似度 ~0.95 < 0.99）。
      // 大小比 100x（100KB 对 10MB）不可能是同一录音转码，Tier2 应拒绝。
      final songs = [
        mk(path: '/a/song_a.flac', title: "Beethoven's 5 Secrets", artist: 'The Piano Guys', durationMs: 200000, ext: 'flac', sizeBytes: 100000),
        mk(path: '/a/song_b.flac', title: "Beethoven's 5 Secret", artist: 'The Piano Guys', durationMs: 200000, ext: 'flac', sizeBytes: 10000000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        titleThreshold: 0.99,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });

    test('Tier2 大小比正常 → 分组（对照）', () async {
      // 与上一测试相同的标题对，大小比 3x（正常转码范围），Tier2 应分组
      final songs = [
        mk(path: '/a/song_a.flac', title: "Beethoven's 5 Secrets", artist: 'The Piano Guys', durationMs: 200000, ext: 'flac', sizeBytes: 30000000),
        mk(path: '/a/song_b.mp3', title: "Beethoven's 5 Secret", artist: 'The Piano Guys', durationMs: 200000, ext: 'mp3', sizeBytes: 10000000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        titleThreshold: 0.99,
        enableFingerprint: false,
      );
      expect(gs.length, 1);
      expect(gs.first.reason, '跨格式/转码重复');
    });

    test('标题带括号非版本标注+同时长 → 跨格式组', () async {
      // "夜曲 (Official Audio)" 归一化后与 "夜曲" 全等；Official Audio
      // 不是版本标记，不拆组。
      // 注：(Live) / (Remastered) 是版本标记，会拆组（见
      // metadata_subdivide_test 的 TEST B 组回归用例），这里用
      // (Official Audio) 保留"括号标注不破坏分组"的原意。
      final songs = [
        mk(path: '/a/夜曲.wav', title: '夜曲', durationMs: 180000, ext: 'wav'),
        mk(path: '/a/夜曲official.flac', title: '夜曲 (Official Audio)', durationMs: 180500, ext: 'flac'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs.length, 1);
    });

    test('标题完全不同+同时长 → 不误判', () async {
      final songs = [
        mk(path: '/a/aaaa.mp3', title: 'aaaa', durationMs: 35000),
        mk(path: '/a/zzzz.mp3', title: 'zzzz', durationMs: 35000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs, isEmpty);
    });
  });

  group('Tier3 模糊匹配（分桶）', () {
    test('标题相似+时长相近（4s差，跨过Tier2的2s桶）→ 一组', () async {
      final songs = [
        mk(path: '/a/s1.mp3', title: 'summer breeze', durationMs: 200000),
        mk(path: '/a/s2.mp3', title: 'summer brezee', durationMs: 204000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs.length, 1);
      expect(gs.first.reason, '标题相似+时长相近');
    });

    test('大量 leftovers 不再静默跳过', () async {
      // 1198 首随机标题 + 1 对已知重复（标题差 1 字符、时长差 3s）。
      // 旧代码 leftovers>800 时直接跳过模糊层，这对已知重复会被漏掉；
      // 新代码按时长分桶，必须能找出它。
      final songs = List.generate(
        1198,
        (i) => mk(
          path: '/a/unique_$i.mp3',
          title: 'qx${(i * 2654435761) % 100000000}jz',
          durationMs: 180000 + i * 173,
        ),
      );
      songs.add(mk(
        path: '/a/knownA.mp3',
        title: 'knownduplicatealpha',
        durationMs: 250000,
      ));
      songs.add(mk(
        path: '/a/knownB.mp3',
        title: 'knownduplicatealphb',
        durationMs: 253000,
      ));
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      final found = gs.any((g) =>
          g.songs.any((s) => s.path == '/a/knownA.mp3') &&
          g.songs.any((s) => s.path == '/a/knownB.mp3'));
      expect(found, isTrue, reason: '模糊层应在 1200 首规模下正常工作');
    });
  });

  group('Tier4 文件内容哈希', () {
    test('文件名/时长全不同但哈希全等 → 一组', () async {
      final songs = [
        mk(path: '/a/aaa.mp3', title: 'aaa', durationMs: 200000, fingerprint: 'deadbeef12345678'),
        mk(path: '/a/zzz.flac', title: 'zzz', durationMs: 300000, ext: 'flac', fingerprint: 'deadbeef12345678'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(songs);
      expect(gs.length, 1);
      expect(gs.first.reason, '文件内容一致');
    });

    test('哈希不同 → 不分组', () async {
      final songs = [
        mk(path: '/a/aaa.mp3', title: 'aaa', durationMs: 200000, fingerprint: 'aaaaaaaaaaaaaaaa'),
        mk(path: '/a/zzz.mp3', title: 'zzz', durationMs: 300000, fingerprint: 'bbbbbbbbbbbbbbbb'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(songs);
      expect(gs, isEmpty);
    });

    test('细分拆成单首后 Tier4 用哈希抓回（漏网回归）', () async {
      // Tier 1 按标题归一化分组（"夜曲 (伴奏)" → "夜曲"），
      // 元数据细分因版本标签不同（伴奏 vs 原版）拆成单首丢弃；
      // Tier 4 必须用哈希把字节相同的两首抓回，而不是只看 remaining。
      final songs = [
        mk(path: '/a/夜曲 (伴奏).mp3', title: '夜曲 (伴奏)', durationMs: 200000, fingerprint: 'abc123abc123abc1'),
        mk(path: '/a/夜曲.mp3', title: '夜曲', durationMs: 200000, fingerprint: 'abc123abc123abc1'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(songs);
      expect(gs.length, 1);
      expect(gs.first.reason, '文件内容一致');
      expect(gs.first.songs.length, 2);
    });

    test('三Z-STUDIO (1) 副本 → 分组（下载后缀不是版本）', () async {
      final songs = [
        mk(path: '/m/三Z-STUDIO&HOYO-MiX - Wifi无处不在.flac', title: '', durationMs: 180000, ext: 'flac', fingerprint: 'f5cd5efddc1a3636'),
        mk(path: '/m/三Z-STUDIO&HOYO-MiX - Wifi无处不在 (1).flac', title: '', durationMs: 180000, ext: 'flac', fingerprint: 'f5cd5efddc1a3636'),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(songs);
      expect(gs.length, 1);
      expect(gs.first.songs.length, 2);
    });
  });

  group('HashWorkerPool', () {
    test('多文件哈希与单文件一致', () async {
      final dir = await Directory.systemTemp.createTemp('pooltest');
      final files = <File>[];
      for (var i = 0; i < 8; i++) {
        final f = File('${dir.path}/f$i.bin');
        await f.writeAsBytes(List.generate(1000, (j) => (i * j) % 256));
        files.add(f);
      }
      final pool = HashWorkerPool(size: 2);
      await pool.start();
      try {
        final results = await Future.wait(
          files.map((f) => pool.hashFile(f.path, 1000, 'bin')),
        );
        expect(results.every((r) => r.isNotEmpty), isTrue);
        expect(results.toSet().length, 8); // 内容各异 → 哈希各异
        // 同一文件重复算，结果一致
        final again = await pool.hashFile(files[0].path, 1000, 'bin');
        expect(again, results[0]);
      } finally {
        await pool.stop();
        await dir.delete(recursive: true);
      }
    });

    test('相同内容 → 同一哈希（时长不参与哈希）', () async {
      // 回归：MediaStore 时长同一文件可能差几毫秒，曾混进哈希导致
      // 字节相同的文件哈希不同、Tier 4 抓不到。现在哈希只取决于
      // 内容 + 大小 + 扩展名，时长抖动不影响。
      final dir = await Directory.systemTemp.createTemp('pooltest-same');
      final bytes = List.generate(2000, (j) => (j * 7) % 256);
      final a = File('${dir.path}/copy_a.flac');
      final b = File('${dir.path}/copy_b.flac');
      await a.writeAsBytes(bytes);
      await b.writeAsBytes(bytes);
      final pool = HashWorkerPool(size: 2);
      await pool.start();
      try {
        final ha = await pool.hashFile(a.path, 2000, 'flac');
        final hb = await pool.hashFile(b.path, 2000, 'flac');
        expect(ha, isNotEmpty);
        expect(hb, ha);
      } finally {
        await pool.stop();
        await dir.delete(recursive: true);
      }
    });
  });
}
