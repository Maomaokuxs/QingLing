import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/ignore_service.dart';
import 'package:song_dedup/services/quality_service.dart';

SongFile mkSong(String path) => SongFile(
      id: 0,
      path: path,
      displayName: path.split('/').last,
      title: 't',
      artist: 'a',
      album: '',
      durationMs: 200000,
      sizeBytes: 5000000,
      extension: 'mp3',
    );

void main() {
  group('IgnoreService', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await IgnoreService.load();
    });

    test('ignore 后 isIgnored 为 true，clear 后恢复', () async {
      expect(IgnoreService.isIgnored('k1'), isFalse);
      await IgnoreService.ignore('k1');
      expect(IgnoreService.isIgnored('k1'), isTrue);
      await IgnoreService.clear();
      expect(IgnoreService.isIgnored('k1'), isFalse);
    });

    test('load 能读回已持久化的忽略项', () async {
      await IgnoreService.ignore('persist-key');
      // 模拟重启：notifier 重置后重新 load
      IgnoreService.ignored.value = {};
      await IgnoreService.load();
      expect(IgnoreService.isIgnored('persist-key'), isTrue);
    });
  });

  group('保留策略 keepBest', () {
    test('keepBest=2 时选中除前二外的全部', () {
      final songs = [
        mkSong('/a/1.flac'),
        mkSong('/a/2.mp3'),
        mkSong('/a/3.mp3'),
        mkSong('/a/4.mp3'),
      ];
      final sorted = QualityService.sortByQualityDesc(songs);
      final sel = QualityService.autoSelectWorst(sorted, keepBest: 2);
      expect(sel.length, 2);
      expect(sel.contains('/a/1.flac'), isFalse);
      expect(sel.contains('/a/2.mp3'), isFalse);
    });

    test('组大小 <= keepBest 时不选中', () {
      final songs = [mkSong('/a/1.flac'), mkSong('/a/2.mp3')];
      final sorted = QualityService.sortByQualityDesc(songs);
      expect(
        QualityService.autoSelectWorst(sorted, keepBest: 2),
        isEmpty,
      );
    });
  });
}
