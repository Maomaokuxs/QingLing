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

    test('同歌+歌手元数据笔误+不同格式 → 跨格式组', () async {
      // 同一首歌转格式时歌手写错一字：归一化 key 不等，
      // 但归一化标题全等（1.0 ≥ 0.9），应被 Tier2 抓住
      final songs = [
        mk(path: '/a/夜曲.flac', title: '夜曲', artist: '周杰伦', durationMs: 210000, ext: 'flac', sizeBytes: 30000000),
        mk(path: '/a/夜曲.mp3', title: '夜曲', artist: '周杰轮', durationMs: 210500, ext: 'mp3', sizeBytes: 8000000),
      ];
      final gs = await SimilarityService.groupSimilarSongsWithFingerprint(
        songs,
        enableFingerprint: false,
      );
      expect(gs.length, 1);
      expect(gs.first.reason, '跨格式/转码重复');
    });

    test('标题带括号版本标注+同时长 → 跨格式组', () async {
      // "夜曲 (Remastered)" 归一化后与 "夜曲" 全等
      final songs = [
        mk(path: '/a/夜曲.wav', title: '夜曲', durationMs: 180000, ext: 'wav'),
        mk(path: '/a/夜曲重制.flac', title: '夜曲 (Remastered)', durationMs: 180500, ext: 'flac'),
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
          files.map((f) => pool.hashFile(f.path, 1000, 60000, 'bin')),
        );
        expect(results.every((r) => r.isNotEmpty), isTrue);
        expect(results.toSet().length, 8); // 内容各异 → 哈希各异
        // 同一文件重复算，结果一致
        final again = await pool.hashFile(files[0].path, 1000, 60000, 'bin');
        expect(again, results[0]);
      } finally {
        await pool.stop();
        await dir.delete(recursive: true);
      }
    });
  });
}
