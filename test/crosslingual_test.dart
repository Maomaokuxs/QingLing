import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/similarity_service.dart';
import 'package:song_dedup/services/chroma_fingerprint_service.dart';

SongFile mkSong(String path) => SongFile(
      id: 0,
      path: path,
      displayName: path.split('/').last,
      title: path.split('/').last,
      artist: 'a',
      album: '',
      durationMs: 200000,
      sizeBytes: 5000000,
      extension: 'flac',
    );

/// 构造 36 维 chroma 向量：3 段，每段 12 维单位向量
List<double> mkFp(List<int> hotIdx) {
  final fp = List<double>.filled(36, 0.0);
  for (var s = 0; s < 3; s++) {
    fp[s * 12 + hotIdx[s]] = 1.0;
  }
  return fp;
}

void main() {
  group('组内版本细分（chroma 聚类）', () {
    test('相同 chroma 指纹的歌曲聚为一类', () {
      final songs = [mkSong('/a.flac'), mkSong('/b.flac')];
      final fp = mkFp([0, 3, 7]);
      final fps = {for (final s in songs) s.path: fp};

      final clusters = SimilarityService.clusterByChroma(songs, fps);

      expect(clusters.length, 1);
      expect(clusters.first.length, 2);
    });

    test('chroma 差异大的歌曲拆分为不同类', () {
      final songs = [mkSong('/a.flac'), mkSong('/b.flac')];
      final fps = {
        songs[0].path: mkFp([0, 0, 0]),
        songs[1].path: mkFp([6, 6, 6]), // 完全不同 -> 相似度 0
      };

      final clusters = SimilarityService.clusterByChroma(songs, fps);

      // 相似度 0 < 0.99，不应聚类
      expect(clusters.length, 2);
    });

    test('相似度低于 0.99 阈值不成簇', () {
      final fp1 = mkFp([0, 0, 0]);
      final fp2 = mkFp([6, 6, 6]);
      expect(ChromaFingerprintService.similarity(fp1, fp2), 0.0);
      expect(ChromaFingerprintService.similarity(fp1, fp2), lessThan(0.99));
    });

    test('相同指纹相似度为 1.0，高于阈值', () {
      final fp = mkFp([0, 3, 7]);
      expect(ChromaFingerprintService.similarity(fp, fp), 1.0);
      expect(ChromaFingerprintService.similarity(fp, fp),
          greaterThanOrEqualTo(0.99));
    });
  });
}
