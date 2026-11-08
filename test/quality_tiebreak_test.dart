import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/quality_service.dart';

SongFile mkFlac(String path, int kbps, int size) => SongFile(
      id: 0,
      path: path,
      displayName: path.split('/').last,
      title: 't',
      artist: 'a',
      album: '',
      durationMs: 165463,
      sizeBytes: size,
      extension: 'flac',
      realBitrateKbps: kbps,
    );

void main() {
  group('音质打平 tie-break', () {
    test('分数打平时码率高的排前面', () {
      // 两个 FLAC 码率分都封顶 400，总分都是 800
      final hi = mkFlac('/hi.flac', 1014, 20976815);
      final lo = mkFlac('/lo.flac', 980, 20278060);
      expect(hi.qualityScore, 800);
      expect(lo.qualityScore, 800);
      // 故意把低码率的放前面，验证排序能纠正
      final sorted = QualityService.sortByQualityDesc([lo, hi]);
      expect(sorted.first.path, '/hi.flac');
      expect(sorted.last.path, '/lo.flac');
    });

    test('自动勾选时保留码率高的那首', () {
      final hi = mkFlac('/hi.flac', 1014, 20976815);
      final lo = mkFlac('/lo.flac', 980, 20278060);
      final sel = QualityService.autoSelectByRule([lo, hi], keepBest: 1);
      expect(sel, {'/lo.flac'});
    });

    test('码率也打平时文件大的优先', () {
      final big = mkFlac('/big.flac', 1000, 21000000);
      final small = mkFlac('/small.flac', 1000, 20000000);
      final sorted = QualityService.sortByQualityDesc([small, big]);
      expect(sorted.first.path, '/big.flac');
    });
  });
}
