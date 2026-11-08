import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 回收站服务 4：安全删除，支持撤销与导出清单
class TrashRecord {
  final String originalPath;
  final String trashPath;
  final int size;
  final String name;
  final DateTime time;

  /// 同一次 moveToTrash 调用的批次标识，用于精确撤销最近一批
  final String batchId;

  TrashRecord({
    required this.originalPath,
    required this.trashPath,
    required this.size,
    required this.name,
    required this.time,
    this.batchId = '',
  });

  Map<String, dynamic> toJson() => {
        'originalPath': originalPath,
        'trashPath': trashPath,
        'size': size,
        'name': name,
        'time': time.toIso8601String(),
        'batchId': batchId,
      };

  factory TrashRecord.fromJson(Map<String, dynamic> j) => TrashRecord(
        originalPath: j['originalPath'] as String,
        trashPath: j['trashPath'] as String,
        size: j['size'] as int,
        name: j['name'] as String,
        time: DateTime.parse(j['time'] as String),
        batchId: j['batchId'] as String? ?? '',
      );
}

class TrashService {
  static const _logName = 'trash_log.json';
  static int _batchSeq = 0;

  /// 单元测试覆盖回收站根目录的钩子；生产代码保持 null 走正常路径。
  static Future<Directory> Function()? testTrashDir;

  static Future<Directory> _trashDir() async {
    if (testTrashDir != null) {
      final dir = await testTrashDir!();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final base =
        await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/trash');
    if (!await dir.exists()) await dir.create(recursive: true);
    // 防止被播放器/媒体库扫到：.nomedia + 隐藏
    try {
      final nomedia = File('${dir.path}/.nomedia');
      if (!await nomedia.exists()) await nomedia.create();
    } catch (_) {}
    return dir;
  }

  static Future<File> _logFile() async {
    final dir = await _trashDir();
    return File('${dir.path}/$_logName');
  }

  /// 将文件移至回收站（复制后保留原路径用于撤销），返回成功移入的记录。
  ///
  /// 注意：只有返回的记录才是成功备份的——调用方删除原文件时必须只删这些，
  /// 没进回收站的文件绝不能动，否则就是丢数据。
  static Future<List<TrashRecord>> moveToTrash(List<String> paths) async {
    final dir = await _trashDir();
    final records = <TrashRecord>[];
    final batchId = '${DateTime.now().millisecondsSinceEpoch}_${_batchSeq++}';
    for (var i = 0; i < paths.length; i++) {
      final p = paths[i];
      try {
        final src = File(p);
        if (!await src.exists()) continue;
        final name = p.split('/').last;
        final ts = DateTime.now().millisecondsSinceEpoch;
        // 同名文件防碰撞：时间戳+序号；极端情况下继续累加直到不重名
        var trashPath = '${dir.path}/${ts}_${i}_$name';
        var dup = 0;
        while (await File(trashPath).exists()) {
          dup++;
          trashPath = '${dir.path}/${ts}_${i}_${dup}_$name';
        }
        await src.copy(trashPath);
        records.add(TrashRecord(
          originalPath: p,
          trashPath: trashPath,
          size: await src.length(),
          name: name,
          time: DateTime.now(),
          batchId: batchId,
        ));
      } catch (_) {}
    }
    if (records.isNotEmpty) {
      final log = await _logFile();
      List<dynamic> existing = [];
      if (await log.exists()) {
        try {
          existing = jsonDecode(await log.readAsString()) as List;
        } catch (_) {}
      }
      existing.addAll(records.map((e) => e.toJson()));
      await log.writeAsString(jsonEncode(existing));
    }
    return records;
  }

  /// 丢弃一批 trash 记录（删文件+清日志）。
  ///
  /// 用于删除被取消时的回滚：系统删除确认弹窗点了取消，原文件还在，
  /// 必须把刚拷进回收站的副本清掉，否则回收站留下"没删掉"的幽灵记录。
  static Future<void> discardRecords(List<TrashRecord> records) async {
    if (records.isEmpty) return;
    final trashPaths = records.map((r) => r.trashPath).toSet();
    for (final r in records) {
      try {
        final f = File(r.trashPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      final log = await _logFile();
      if (await log.exists()) {
        final list = jsonDecode(await log.readAsString()) as List;
        list.removeWhere((e) =>
            trashPaths.contains(Map<String, dynamic>.from(e)['trashPath']));
        await log.writeAsString(jsonEncode(list));
      }
    } catch (_) {}
  }

  /// 撤销最近一次回收站操作。
  ///
  /// 按 batchId 精确判定"最近一批"（无 batchId 的旧记录回退到 5 秒时间窗口）。
  static Future<int> restoreLastBatch() async {
    final log = await _logFile();
    if (!await log.exists()) return 0;
    List<dynamic> list;
    try {
      list = jsonDecode(await log.readAsString()) as List;
    } catch (_) {
      return 0;
    }
    if (list.isEmpty) return 0;
    list.sort((a, b) => DateTime.parse(a['time'] as String)
        .compareTo(DateTime.parse(b['time'] as String)));
    final last = Map<String, dynamic>.from(list.last);
    final batchId = last['batchId'] as String? ?? '';
    final List<dynamic> batch;
    if (batchId.isNotEmpty) {
      batch = list
          .where((e) =>
              (Map<String, dynamic>.from(e)['batchId'] as String? ?? '') ==
              batchId)
          .toList();
    } else {
      // 兼容旧记录：退回时间窗口判定
      final lastTime = DateTime.parse(last['time'] as String);
      batch = list
          .where((e) =>
              lastTime
                  .difference(DateTime.parse(e['time'] as String))
                  .inSeconds
                  .abs() <
              5)
          .toList();
    }
    int restored = 0;
    for (final j in batch) {
      final r = TrashRecord.fromJson(Map<String, dynamic>.from(j));
      try {
        final trashFile = File(r.trashPath);
        if (await trashFile.exists()) {
          final dest = File(r.originalPath);
          await dest.parent.create(recursive: true);
          await trashFile.copy(r.originalPath);
          try {
            await const MethodChannel('song_dedup/scanner')
                .invokeMethod('scanFile', {'path': r.originalPath});
          } catch (_) {}
          // 保留 trash 副本直到用户手动清理
          restored++;
        }
      } catch (_) {}
    }
    // 从日志移除已恢复的批次
    list.removeWhere((e) => batch.contains(e));
    await log.writeAsString(jsonEncode(list));
    return restored;
  }

  /// 导出清单到 Download/清聆_回收站/清单
  static Future<String?> exportList(List<TrashRecord> records) async {
    try {
      Directory? dl;
      try {
        dl = Directory('/storage/emulated/0/Download');
        if (!await dl.exists()) dl = await getExternalStorageDirectory();
      } catch (_) {
        dl = await getExternalStorageDirectory();
      }
      if (dl == null) return null;
      final trashExportDir = Directory('${dl.path}/清聆_回收站');
      if (!await trashExportDir.exists()) {
        await trashExportDir.create(recursive: true);
      }
      final file = File(
          '${trashExportDir.path}/清单_${DateTime.now().millisecondsSinceEpoch}.txt');
      final buf = StringBuffer();
      buf.writeln('清聆 删除清单 ${DateTime.now()}');
      buf.writeln('共 ${records.length} 个文件');
      buf.writeln('---');
      for (final r in records) {
        buf.writeln('${r.name} | ${r.size}B | ${r.originalPath}');
      }
      await file.writeAsString(buf.toString());
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static Future<List<TrashRecord>> loadLog() async {
    final log = await _logFile();
    if (!await log.exists()) return [];
    try {
      final list = jsonDecode(await log.readAsString()) as List;
      return list
          .map((e) => TrashRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> restoreOne(TrashRecord r) async {
    try {
      final trashFile = File(r.trashPath);
      if (!await trashFile.exists()) return false;
      final dest = File(r.originalPath);
      await dest.parent.create(recursive: true);
      await trashFile.copy(r.originalPath);
      try {
        await const MethodChannel('song_dedup/scanner')
            .invokeMethod('scanFile', {'path': r.originalPath});
      } catch (_) {}
      // 从日志移除
      final log = await _logFile();
      if (await log.exists()) {
        final list = jsonDecode(await log.readAsString()) as List;
        list.removeWhere((e) =>
            Map<String, dynamic>.from(e)['trashPath'] == r.trashPath);
        await log.writeAsString(jsonEncode(list));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 永久删除单条（删回收站副本并清日志）
  static Future<bool> deletePermanentOne(TrashRecord r) async {
    try {
      final f = File(r.trashPath);
      if (await f.exists()) await f.delete();
      final log = await _logFile();
      if (await log.exists()) {
        final list = jsonDecode(await log.readAsString()) as List;
        list.removeWhere((e) =>
            Map<String, dynamic>.from(e)['trashPath'] == r.trashPath);
        await log.writeAsString(jsonEncode(list));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删除超过 maxAge 的回收站记录（删文件+清日志），返回清理数量。
  /// 用于"回收站自动清理"设置，在应用启动时执行一次。
  static Future<int> purgeExpired(Duration maxAge) async {
    final log = await _logFile();
    if (!await log.exists()) return 0;
    List<dynamic> list;
    try {
      list = jsonDecode(await log.readAsString()) as List;
    } catch (_) {
      return 0;
    }
    if (list.isEmpty) return 0;
    final now = DateTime.now();
    final expired = <dynamic>[];
    for (final e in list) {
      try {
        final m = Map<String, dynamic>.from(e as Map);
        final t = DateTime.parse(m['time'] as String);
        if (now.difference(t) > maxAge) expired.add(e);
      } catch (_) {}
    }
    for (final e in expired) {
      try {
        final f =
            File(Map<String, dynamic>.from(e as Map)['trashPath'] as String);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    list.removeWhere((e) => expired.contains(e));
    try {
      await log.writeAsString(jsonEncode(list));
    } catch (_) {}
    return expired.length;
  }

  /// 清空回收站
  static Future<void> clearAll() async {
    final dir = await _trashDir();
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e.path.endsWith(_logName)) continue;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
    final log = await _logFile();
    if (await log.exists()) await log.writeAsString('[]');
  }

  static String formatSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
