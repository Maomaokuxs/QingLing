import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/services/update_service.dart';

/// 更新检查回归测试：版本号比较与 release JSON 解析（纯函数，不联网）。
void main() {
  group('isNewerVersion 版本比较', () {
    test('release 高一位 → 有更新', () {
      expect(UpdateService.isNewerVersion('0.2.2', '0.2.1+2026'), isTrue);
      expect(UpdateService.isNewerVersion('0.3.0', '0.2.1+2026'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.0', '0.2.1+2026'), isTrue);
    });

    test('版本号相等（build 号不同也不算新）→ 无更新', () {
      expect(UpdateService.isNewerVersion('0.2.1', '0.2.1+2026'), isFalse);
      expect(UpdateService.isNewerVersion('0.2.1', '0.2.1+1'), isFalse);
    });

    test('release 更低 → 无更新', () {
      expect(UpdateService.isNewerVersion('0.2.0', '0.2.1+2026'), isFalse);
      expect(UpdateService.isNewerVersion('0.1.9', '0.2.1+2026'), isFalse);
    });

    test('tag 带 v 前缀、版本号缺段都能比', () {
      expect(UpdateService.isNewerVersion('v0.2.2', '0.2.1+2026'), isTrue);
      expect(UpdateService.isNewerVersion('0.3', '0.2.1+2026'), isTrue);
      expect(UpdateService.isNewerVersion('1', '0.2.1+2026'), isTrue);
    });

    test('解析失败 → 不报假更新', () {
      expect(UpdateService.isNewerVersion('', '0.2.1+2026'), isFalse);
      expect(UpdateService.isNewerVersion('abc', '0.2.1+2026'), isFalse);
      expect(UpdateService.isNewerVersion('0.2.1', 'xyz'), isFalse);
      expect(UpdateService.isNewerVersion('0.2.1.4', '0.2.1+2026'), isFalse);
    });
  });

  group('UpdateInfo.fromReleaseJson', () {
    Map<String, dynamic> releaseJson({List<Map<String, dynamic>>? assets}) {
      return {
        'tag_name': 'v0.2.2',
        'name': '清聆 0.2.2',
        'body': '修复若干问题',
        'assets':
            assets ??
            [
              {
                'name': 'app-release.apk',
                'browser_download_url':
                    'https://github.com/Maomaokuxs/QingLing/releases/download/v0.2.2/app-release.apk',
                'size': 20132659,
              },
            ],
      };
    }

    test('正常 release 解析出版本、说明与 APK 地址', () {
      final info = UpdateInfo.fromReleaseJson(releaseJson());
      expect(info, isNotNull);
      expect(info!.tag, 'v0.2.2');
      expect(info.version, '0.2.2');
      expect(info.name, '清聆 0.2.2');
      expect(info.notes, '修复若干问题');
      expect(info.apkUrl.contains('app-release.apk'), isTrue);
      expect(info.apkSizeBytes, 20132659);
    });

    test('无 APK 资源 → null（不当成可用更新）', () {
      expect(
        UpdateInfo.fromReleaseJson(
          releaseJson(
            assets: [
              {
                'name': 'notes.txt',
                'browser_download_url': 'https://example.com/notes.txt',
                'size': 123,
              },
            ],
          ),
        ),
        isNull,
      );
      expect(UpdateInfo.fromReleaseJson(releaseJson(assets: [])), isNull);
    });

    test('多个资源时挑出 .apk 的那一个', () {
      final info = UpdateInfo.fromReleaseJson(
        releaseJson(
          assets: [
            {
              'name': 'checksums.txt',
              'browser_download_url': 'https://example.com/checksums.txt',
              'size': 100,
            },
            {
              'name': 'app-release.apk',
              'browser_download_url': 'https://example.com/app-release.apk',
              'size': 999,
            },
          ],
        ),
      );
      expect(info, isNotNull);
      expect(info!.apkUrl, 'https://example.com/app-release.apk');
      expect(info.apkSizeBytes, 999);
    });
  });
}
