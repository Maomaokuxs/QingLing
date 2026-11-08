import 'package:flutter/services.dart';

/// 系统分享（ACTION_SEND），用于导出清理报告等文本分享。
class ShareService {
  static const _ch = MethodChannel('song_dedup/scanner');

  static Future<void> shareText(String text, {String title = '分享'}) async {
    try {
      await _ch.invokeMethod('shareText', {'text': text, 'title': title});
    } catch (_) {
      // 分享失败静默忽略
    }
  }
}
