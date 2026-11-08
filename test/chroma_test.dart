import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/duplicate_group.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/chroma_fingerprint_service.dart';
import 'package:song_dedup/services/similarity_service.dart';

SongFile _song(String path) => SongFile(
      id: path.hashCode,
      path: path,
      displayName: path.split('/').last,
      title: 'test',
      artist: 'artist',
      album: '',
      durationMs: 200000,
      sizeBytes: 1000,
      extension: 'flac',
      dateModified: 0,
    );

/// 构造 36 维测试向量：每段 12 维按 pattern 填充并归一化。
List<double> _fullVec(double Function(int seg, int pc) pattern) {
  final v = List<double>.filled(36, 0.0);
  for (var s = 0; s < 3; s++) {
    var norm = 0.0;
    for (var i = 0; i < 12; i++) {
      norm += pattern(s, i) * pattern(s, i);
    }
    norm = sqrt(norm);
    for (var i = 0; i < 12; i++) {
      v[s * 12 + i] = pattern(s, i) / norm;
    }
  }
  return v;
}

void main() {
  group('chroma similarity', () {
    test('identical vectors -> 1.0', () {
      final a = _fullVec((s, i) => (i + s * 3) % 7 + 1.0);
      expect(ChromaFingerprintService.similarity(a, a), closeTo(1.0, 1e-9));
    });

    test('different patterns -> well below threshold', () {
      final a = _fullVec((s, i) => (i + s * 3) % 7 + 1.0);
      final b = _fullVec((s, i) => (i * 5 + s) % 11 + 1.0);
      expect(ChromaFingerprintService.similarity(a, b), lessThan(0.99));
    });
  });

  group('clusterByChroma', () {
    test('same-audio clusters together, different splits', () {
      final s1 = _song('/a.flac');
      final s2 = _song('/b.flac');
      final s3 = _song('/c.flac');
      final fp1 = _fullVec((s, i) => (i + s * 3) % 7 + 1.0);
      final fp2 = List<double>.from(fp1); // 同一录音
      final fp3 = _fullVec((s, i) => (i * 5 + s) % 11 + 1.0); // 不同
      final clusters = SimilarityService.clusterByChroma(
          [s1, s2, s3],
          {'/a.flac': fp1, '/b.flac': fp2, '/c.flac': fp3});
      expect(clusters.length, 2);
      final sizes = clusters.map((c) => c.length).toList()..sort();
      expect(sizes, [1, 2]);
    });

    test('missing fingerprint merges into main cluster', () {
      final s1 = _song('/a.flac');
      final s2 = _song('/b.flac'); // 无指纹
      final clusters = SimilarityService.clusterByChroma(
          [s1, s2], {'/a.flac': _fullVec((s, i) => 1.0)});
      expect(clusters.length, 1);
      expect(clusters.first.length, 2);
    });

    test('all missing -> single cluster (no subdivision)', () {
      final songs = [_song('/a.flac'), _song('/b.flac')];
      final clusters = SimilarityService.clusterByChroma(songs, {});
      expect(clusters.length, 1);
    });
  });

  group('DuplicateGroup noAutoSelect', () {
    test('json round-trip', () {
      final g = DuplicateGroup(
        key: 'k::ver1',
        songs: [_song('/a.flac')],
        displayTitle: 't',
        reason: '同名不同版本',
        noAutoSelect: true,
      );
      final g2 = DuplicateGroup.fromJson(g.toJson());
      expect(g2.noAutoSelect, true);
      expect(g2.reason, '同名不同版本');
    });

    test('defaults to false', () {
      final g = DuplicateGroup(
        key: 'k',
        songs: [_song('/a.flac')],
        displayTitle: 't',
        reason: '标题/歌手一致',
      );
      expect(g.noAutoSelect, false);
      final g2 = DuplicateGroup.fromJson(g.toJson());
      expect(g2.noAutoSelect, false);
    });
  });
}
