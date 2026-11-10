import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/quality_service.dart';
import 'package:song_dedup/services/similarity_service.dart';
import 'package:song_dedup/services/spectral_analysis_service.dart';

SongFile mkFlac(String path, {int bitrateKbps = 900}) {
  final name = path.split('/').last;
  return SongFile(
    id: 0,
    path: path,
    displayName: name,
    title: 'Test Song',
    artist: 'Test Artist',
    album: '',
    durationMs: 200000,
    sizeBytes: 20000000,
    extension: 'flac',
    realBitrateKbps: bitrateKbps,
  );
}

void main() {
  group('SpectralResult 判定', () {
    test('44.1kHz 真 FLAC：截止 21kHz 不判假', () {
      const r = SpectralResult(cutoffHz: 21000, sampleRate: 44100);
      expect(r.isFakeLossless, isFalse);
    });

    test('44.1kHz 假 FLAC：128k 来源截止 16.5kHz 判假，估 128k', () {
      const r = SpectralResult(cutoffHz: 16500, sampleRate: 44100);
      expect(r.isFakeLossless, isTrue);
      expect(r.estimatedTrueBitrateKbps, 128);
    });

    test('44.1kHz 假 FLAC：192k 来源截止 18.5kHz 判假，估 192k', () {
      const r = SpectralResult(cutoffHz: 18500, sampleRate: 44100);
      expect(r.isFakeLossless, isTrue);
      expect(r.estimatedTrueBitrateKbps, 192);
    });

    test('44.1kHz 320k 来源截止 20kHz：比值 0.907，不判（宁可漏过）', () {
      const r = SpectralResult(cutoffHz: 20000, sampleRate: 44100);
      expect(r.isFakeLossless, isFalse);
    });

    test('边界 0.85~0.90 不判：256k 来源截止 19.6kHz', () {
      const r = SpectralResult(cutoffHz: 19600, sampleRate: 44100);
      expect(r.isFakeLossless, isFalse);
    });

    test('44.1k 升到 96k：截止 22kHz 比值 0.23，判假', () {
      const r = SpectralResult(cutoffHz: 22000, sampleRate: 96000);
      expect(r.isFakeLossless, isTrue);
    });

    test('已知局限：44.1k 升到 48k 截止 22kHz 比值 0.92，抓不到', () {
      // 44.1k 内容升到 48k 后截止仍在 22kHz 附近，与真 48k 母带
      // 自然滚降重叠，单靠截止频率分不出来，不判（宁可漏过）。
      const r = SpectralResult(cutoffHz: 22000, sampleRate: 48000);
      expect(r.isFakeLossless, isFalse);
    });

    test('96kHz 真高解析：截止 48kHz 不判假', () {
      const r = SpectralResult(cutoffHz: 47000, sampleRate: 96000);
      expect(r.isFakeLossless, isFalse);
    });
  });

  group('SongFile 有效音质分', () {
    test('未分析的 FLAC：有效分等于标称分', () {
      final f = mkFlac('/a.flac');
      expect(f.effectiveQualityScore, f.qualityScore);
      expect(f.isFakeLossless, isFalse);
    });

    test('假 FLAC（128k 来源）：有效分按 MP3 128k 重算，约 360', () {
      final f = mkFlac('/a.flac');
      f.spectral = const SpectralResult(cutoffHz: 16500, sampleRate: 44100);
      expect(f.isFakeLossless, isTrue);
      expect(f.effectiveQualityScore, 200 + (128 / 320 * 400).round());
      expect(f.effectiveQualityLabel, '标准');
    });

    test('假 FLAC（192k 来源）：有效分约 440，标签标准', () {
      final f = mkFlac('/a.flac');
      f.spectral = const SpectralResult(cutoffHz: 18500, sampleRate: 44100);
      expect(f.effectiveQualityScore, 200 + (192 / 320 * 400).round());
      expect(f.effectiveQualityLabel, '标准');
    });

    test('MP3 文件即使有频谱结果也不判假（只对无损格式）', () {
      final name = 'a.mp3';
      final f = SongFile(
        id: 0,
        path: '/$name',
        displayName: name,
        title: 'Test',
        artist: 'A',
        album: '',
        durationMs: 200000,
        sizeBytes: 5000000,
        extension: 'mp3',
        realBitrateKbps: 320,
      );
      f.spectral = const SpectralResult(cutoffHz: 16500, sampleRate: 44100);
      expect(f.isFakeLossless, isFalse);
      expect(f.effectiveQualityScore, f.qualityScore);
    });

    test('频谱结果可序列化往返（扫描缓存）', () {
      final f = mkFlac('/a.flac');
      f.spectral = const SpectralResult(cutoffHz: 16500, sampleRate: 44100);
      final restored = SongFile.fromJson(f.toJson());
      expect(restored.isFakeLossless, isTrue);
      expect(restored.spectral?.cutoffHz, 16500);
      expect(restored.spectral?.sampleRate, 44100);
    });
  });

  group('QualityService 排序', () {
    test('真 FLAC 排在假 FLAC 前面', () {
      final genuine = mkFlac('/genuine.flac', bitrateKbps: 900);
      final fake = mkFlac('/fake.flac', bitrateKbps: 900);
      fake.spectral =
          const SpectralResult(cutoffHz: 16500, sampleRate: 44100);
      final sorted =
          QualityService.sortByQualityDesc([fake, genuine]);
      expect(sorted.first.path, '/genuine.flac');
      expect(sorted.last.path, '/fake.flac');
    });

    test('假 FLAC 与真 320k MP3 同组：假 FLAC 有效分 360，MP3 排前面', () {
      final fake = mkFlac('/fake.flac', bitrateKbps: 900);
      fake.spectral =
          const SpectralResult(cutoffHz: 16500, sampleRate: 44100);
      final mp3 = SongFile(
        id: 0,
        path: '/real.mp3',
        displayName: 'real.mp3',
        title: 'Test Song',
        artist: 'Test Artist',
        album: '',
        durationMs: 200000,
        sizeBytes: 8000000,
        extension: 'mp3',
        realBitrateKbps: 320,
      );
      final sorted = QualityService.sortByQualityDesc([fake, mp3]);
      expect(sorted.first.path, '/real.mp3');
    });
  });

  group('开关默认关', () {
    test('enableSpectral=false：分组不跑频谱，spectral 为空、不降级', () async {
      final genuine = mkFlac('/genuine.flac', bitrateKbps: 900);
      final fake = mkFlac('/fake.flac', bitrateKbps: 900);
      final groups =
          await SimilarityService.groupSimilarSongsWithFingerprint(
        [genuine, fake],
        enableFingerprint: false,
        enableCrossLingual: false,
        enableSpectral: false,
      );
      expect(groups.length, 1);
      for (final s in groups.first.songs) {
        expect(s.spectral, isNull);
        expect(s.isFakeLossless, isFalse);
      }
      // 未降级：两首同分同码率，顺序不变（不因假无损重排）
      expect(groups.first.songs.first.effectiveQualityScore,
          groups.first.songs.first.qualityScore);
    });

    test('enableSpectral 默认值 false', () async {
      final genuine = mkFlac('/genuine.flac', bitrateKbps: 900);
      final fake = mkFlac('/fake.flac', bitrateKbps: 900);
      final groups =
          await SimilarityService.groupSimilarSongsWithFingerprint(
        [genuine, fake],
        enableFingerprint: false,
        enableCrossLingual: false,
      );
      expect(groups.length, 1);
      for (final s in groups.first.songs) {
        expect(s.spectral, isNull);
      }
    });
  });
}
