import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/services/acoustic_fingerprint_service.dart';

void main() {
  group('hammingDistance', () {
    test('相同指纹距离为 0', () {
      const fp = '0123456789abcdef01234567';
      expect(AcousticFingerprintService.hammingDistance(fp, fp), 0);
    });

    test('差 1 bit 距离为 1', () {
      const a = '000000000000000000000000';
      const b = '000000000000000000000001';
      expect(AcousticFingerprintService.hammingDistance(a, b), 1);
    });

    test('全反距离为 96', () {
      const a = '000000000000000000000000';
      const b = 'ffffffffffffffffffffffff';
      expect(AcousticFingerprintService.hammingDistance(a, b), 96);
    });

    test('长度非法返回 -1', () {
      expect(AcousticFingerprintService.hammingDistance('abc', 'abc'), -1);
      expect(AcousticFingerprintService.hammingDistance(
          'zzzzzzzzzzzzzzzzzzzzzzzz', '000000000000000000000000'), -1);
    });
  });

  group('isSameAudio 稀疏信号', () {
    // 真机实测：440Hz vs 880Hz 纯音指纹
    // A=002000000020000000200000, B=000200000002000000020000
    // 汉明距离 6，但并集仅 6 位 -> 稀疏，用严格阈值 2，必须判不同
    test('稀疏纯音：距离 6 也判不同', () {
      const a = '002000000020000000200000';
      const b = '000200000002000000020000';
      expect(AcousticFingerprintService.hammingDistance(a, b), 6);
      expect(AcousticFingerprintService.isSameAudio(a, b), isFalse);
    });

    test('稀疏纯音：完全相同判同', () {
      const a = '002000000020000000200000';
      expect(AcousticFingerprintService.isSameAudio(a, a), isTrue);
    });

    test('稠密信号：夜曲 FLAC/MP3 指纹相同判同', () {
      const fp = '7ea000007ea000007ea00000';
      expect(AcousticFingerprintService.isSameAudio(fp, fp), isTrue);
    });
  });

  group('isSameAudio 分段阈值', () {
    test('每段差 3 位以内判同', () {
      const base = 'ffffffffffffffffffffffff';
      // 每段末 16 位 ffff -> fff8：各差 3 位
      const close = 'fffffff8fffffff8fffffff8';
      expect(AcousticFingerprintService.hammingDistance(base, close), 9);
      expect(AcousticFingerprintService.isSameAudio(base, close), isTrue);
    });

    test('某一段差 4 位即判不同', () {
      const base = 'ffffffffffffffffffffffff';
      // 仅最后一段 ffff -> fff0：差 4 位
      const far = 'fffffffffffffffffffffff0';
      expect(AcousticFingerprintService.isSameAudio(base, far), isFalse);
    });

    test('全零指纹不参与分组', () {
      const z = '000000000000000000000000';
      expect(AcousticFingerprintService.isSameAudio(z, z), isFalse);
    });
  });
}
