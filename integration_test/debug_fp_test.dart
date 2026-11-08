import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('debug native error', (tester) async {
    const ch = MethodChannel('song_dedup/scanner');
    try {
      final r = await ch.invokeMethod(
          'audioFingerprint', {'id': 6035, 'path': '/sdcard/Music/testsongA.wav'});
      print('RESULT: $r');
    } catch (e) {
      print('EXCEPTION: $e');
    }
    // 同时测已有的 analyzeSpectrum，看是不是环境问题
    try {
      final r2 = await ch.invokeMethod(
          'analyzeSpectrum', {'id': 6035, 'path': '/sdcard/Music/testsongA.wav'});
      print('SPECTRUM RESULT: $r2');
    } catch (e) {
      print('SPECTRUM EXCEPTION: $e');
    }
  });
}
