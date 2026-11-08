import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:song_dedup/services/acoustic_fingerprint_service.dart';

/// 真机声纹验证：用手机上的测试音频验证 native 音频指纹。
/// 运行：flutter test integration_test/acoustic_fp_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('acoustic fingerprint distances on device',
      (tester) async {
    const base = '/sdcard/Music';
    final fpFlac =
        await AcousticFingerprintService.fingerprint(6041, '$base/夜曲-周杰伦.flac');
    final fpMp3 =
        await AcousticFingerprintService.fingerprint(6042, '$base/夜曲-周杰伦.mp3');
    final fpA =
        await AcousticFingerprintService.fingerprint(6035, '$base/testsongA.wav');
    final fpB =
        await AcousticFingerprintService.fingerprint(6036, '$base/testsongB.wav');
    final fpFake =
        await AcousticFingerprintService.fingerprint(6043, '$base/假无损测试.flac');
    final fpTrue =
        await AcousticFingerprintService.fingerprint(6044, '$base/真无损测试.flac');

    print('FP flac: $fpFlac');
    print('FP mp3 : $fpMp3');
    print('FP A   : $fpA');
    print('FP B   : $fpB');
    print('FP fake: $fpFake');
    print('FP true: $fpTrue');

    for (final fp in [fpFlac, fpMp3, fpA, fpB, fpFake, fpTrue]) {
      expect(fp, isNotNull);
      expect(fp!.length, 24);
    }

    final dSame =
        AcousticFingerprintService.hammingDistance(fpFlac!, fpMp3!);
    final dDiff = AcousticFingerprintService.hammingDistance(fpA!, fpB!);
    final dLossy =
        AcousticFingerprintService.hammingDistance(fpFake!, fpTrue!);
    print('DIST same-song flac/mp3 = $dSame');
    print('DIST testsongA/B       = $dDiff');
    print('DIST fake/true lossless= $dLossy');

    // 同一音频不同格式：必须判同
    expect(dSame,
        lessThanOrEqualTo(AcousticFingerprintService.sameThreshold));
    // 不同音频：必须判不同
    expect(dDiff, greaterThan(AcousticFingerprintService.sameThreshold));
  });
}
