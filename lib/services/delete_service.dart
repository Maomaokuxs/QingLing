import 'dart:io';
import 'package:flutter/services.dart';

class DeleteService {
  static const _channel = MethodChannel('song_dedup/delete');

  /// 删除文件，优先走 MediaStore（Android 10+ 需用户确认，插件会自动拉起系统弹框）
  /// 返回成功删除的路径列表
  static Future<List<String>> deleteFiles(List<String> paths, List<int> ids) async {
    // 优先尝试原生 MediaStore 删除
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('deleteSongs', {
        'ids': ids,
        'paths': paths,
      });
      if (result != null) {
        return result.cast<String>();
      }
    } on MissingPluginException {
      // 降级到 Dart 删除
    } catch (e) {
      // 原生删除失败（用户取消等），抛出让上层提示
      rethrow;
    }

    // Fallback: 直接文件删除 + 通知媒体库（Android 10 以下或未实现 channel 时）
    final deleted = <String>[];
    for (final p in paths) {
      try {
        final f = File(p);
        if (await f.exists()) {
          await f.delete();
          deleted.add(p);
        }
      } catch (_) {}
    }
    return deleted;
  }
}
