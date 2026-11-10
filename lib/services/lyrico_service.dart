import 'package:flutter/services.dart';

import '../models/song_file.dart';

/// 调 Lyrico 外部编辑（改标签、歌词、封面）的结果。
enum LyricoEditResult {
  /// 用户在 Lyrico 里点了 ✓ 保存并返回
  saved,

  /// 用户未保存退出
  cancelled,

  /// 手机上没装 Lyrico
  notInstalled,
}

/// Lyrico 外部编辑：经原生发 Intent com.lonx.lyrico.action.EDIT_TAG，
/// 包名 com.lonx.lyrico（先试正式版，未装再试 debug 版），传 MediaStore
/// content URI + 读写授权。Lyrico 保存后返回 RESULT_OK，未保存返回
/// RESULT_CANCELED。原生在 onActivityResult 里把结果回传给这里的 await。
class LyricoService {
  static const _ch = MethodChannel('song_dedup/scanner');

  /// Lyrico GitHub releases（未安装时引导下载）。
  static const releaseUrl = 'https://github.com/Replica0110/Lyrico/releases';

  /// 打开 Lyrico 单曲编辑页。返回保存与否；未安装时返回 notInstalled。
  static Future<LyricoEditResult> editSong(SongFile song) async {
    try {
      final res = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'editWithLyrico',
        {'id': song.id, 'path': song.path},
      );
      final saved = (res?['saved'] as bool?) ?? false;
      return saved ? LyricoEditResult.saved : LyricoEditResult.cancelled;
    } on PlatformException catch (e) {
      if (e.code == 'NOT_INSTALLED') return LyricoEditResult.notInstalled;
      rethrow;
    }
  }

  /// 用系统浏览器打开一个链接（未安装 Lyrico 时引导下载）。
  static Future<void> openUrl(String url) async {
    await _ch.invokeMethod('openUrl', {'url': url});
  }
}
