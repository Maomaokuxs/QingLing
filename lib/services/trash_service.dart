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
  TrashRecord({required this.originalPath, required this.trashPath, required this.size, required this.name, required this.time});
  Map<String,dynamic> toJson()=> {'originalPath':originalPath,'trashPath':trashPath,'size':size,'name':name,'time':time.toIso8601String()};
  factory TrashRecord.fromJson(Map<String,dynamic> j)=> TrashRecord(originalPath:j['originalPath'], trashPath:j['trashPath'], size:j['size'], name:j['name'], time:DateTime.parse(j['time']));
}

class TrashService {
  static const _logName = 'trash_log.json';

  static Future<Directory> _trashDir() async {
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/trash');
    if(!await dir.exists()) await dir.create(recursive:true);
    // 防止被播放器/媒体库扫到：.nomedia + 隐藏
    try{
      final nomedia = File('${dir.path}/.nomedia');
      if(!await nomedia.exists()) await nomedia.create();
    }catch(_){}
    return dir;
  }

  static Future<File> _logFile() async {
    final dir = await _trashDir();
    return File('${dir.path}/$_logName');
  }

  /// 将文件移至回收站（复制后保留原路径用于撤销），返回成功移入的记录
  static Future<List<TrashRecord>> moveToTrash(List<String> paths) async {
    final dir = await _trashDir();
    final records = <TrashRecord>[];
    for(final p in paths){
      try{
        final src = File(p);
        if(!await src.exists()) continue;
        final name = p.split('/').last;
        final ts = DateTime.now().millisecondsSinceEpoch;
        final trashPath = '${dir.path}/${ts}_$name';
        await src.copy(trashPath);
        records.add(TrashRecord(originalPath:p, trashPath:trashPath, size: await src.length(), name:name, time:DateTime.now()));
      }catch(_){}
    }
    if(records.isNotEmpty){
      final log = await _logFile();
      List<dynamic> existing = [];
      if(await log.exists()){
        try{ existing = jsonDecode(await log.readAsString()) as List; }catch(_){}
      }
      existing.addAll(records.map((e)=>e.toJson()));
      await log.writeAsString(jsonEncode(existing));
    }
    return records;
  }

  /// 撤销最近一次回收站操作
  static Future<int> restoreLastBatch() async {
    final log = await _logFile();
    if(!await log.exists()) return 0;
    List<dynamic> list;
    try{ list = jsonDecode(await log.readAsString()) as List; }catch(_){ return 0; }
    if(list.isEmpty) return 0;
    // 取最后一次批次（按时间相近的连续记录，取最近的 size 个？简化：恢复最近一次 moveToTrash 的批次，即时间最晚的 N 条且时间差<5秒）
    list.sort((a,b)=> DateTime.parse(a['time']).compareTo(DateTime.parse(b['time'])));
    final lastTime = DateTime.parse(list.last['time']);
    final batch = list.where((e)=> lastTime.difference(DateTime.parse(e['time'])).inSeconds.abs() < 5).toList();
    int restored=0;
    for(final j in batch){
      final r = TrashRecord.fromJson(Map<String,dynamic>.from(j));
      try{
        final trashFile = File(r.trashPath);
        if(await trashFile.exists()){
          final dest = File(r.originalPath);
          await dest.parent.create(recursive:true);
          await trashFile.copy(r.originalPath);
          try{ await const MethodChannel('song_dedup/scanner').invokeMethod('scanFile', {'path': r.originalPath}); }catch(_){}
          // 保留 trash 副本直到用户手动清理
          restored++;
        }
      }catch(_){}
    }
    // 从日志移除已恢复的批次
    list.removeWhere((e)=> batch.contains(e));
    await log.writeAsString(jsonEncode(list));
    return restored;
  }

  /// 导出清单到 Download/清聆_回收站/清单
  static Future<String?> exportList(List<TrashRecord> records) async {
    try{
      Directory? dl;
      try{
        dl = Directory('/storage/emulated/0/Download');
        if(!await dl.exists()) dl = await getExternalStorageDirectory();
      }catch(_){
        dl = await getExternalStorageDirectory();
      }
      if(dl==null) return null;
      final trashExportDir = Directory('${dl.path}/清聆_回收站');
      if(!await trashExportDir.exists()) await trashExportDir.create(recursive:true);
      final file = File('${trashExportDir.path}/清单_${DateTime.now().millisecondsSinceEpoch}.txt');
      final buf = StringBuffer();
      buf.writeln('清聆 删除清单 ${DateTime.now()}');
      buf.writeln('共 ${records.length} 个文件');
      buf.writeln('---');
      for(final r in records){
        buf.writeln('${r.name} | ${r.size}B | ${r.originalPath}');
      }
      await file.writeAsString(buf.toString());
      return file.path;
    }catch(_){ return null; }
  }

  static Future<List<TrashRecord>> loadLog() async {
    final log = await _logFile();
    if(!await log.exists()) return [];
    try{
      final list = jsonDecode(await log.readAsString()) as List;
      return list.map((e)=> TrashRecord.fromJson(Map<String,dynamic>.from(e))).toList();
    }catch(_){ return []; }
  }

  static Future<bool> restoreOne(TrashRecord r) async {
    try{
      final trashFile = File(r.trashPath);
      if(!await trashFile.exists()) return false;
      final dest = File(r.originalPath);
      await dest.parent.create(recursive:true);
      await trashFile.copy(r.originalPath);
      try{ await const MethodChannel('song_dedup/scanner').invokeMethod('scanFile', {'path': r.originalPath}); }catch(_){}
      // 从日志移除
      final log = await _logFile();
      if(await log.exists()){
        final list = jsonDecode(await log.readAsString()) as List;
        list.removeWhere((e)=> Map<String,dynamic>.from(e)['trashPath']==r.trashPath);
        await log.writeAsString(jsonEncode(list));
      }
      return true;
    }catch(_){ return false; }
  }

  /// 永久删除单条（删回收站副本并清日志）
  static Future<bool> deletePermanentOne(TrashRecord r) async {
    try{
      final f = File(r.trashPath);
      if(await f.exists()) await f.delete();
      final log = await _logFile();
      if(await log.exists()){
        final list = jsonDecode(await log.readAsString()) as List;
        list.removeWhere((e)=> Map<String,dynamic>.from(e)['trashPath']==r.trashPath);
        await log.writeAsString(jsonEncode(list));
      }
      return true;
    }catch(_){ return false; }
  }

  /// 清空回收站
  static Future<void> clearAll() async {
    final dir = await _trashDir();
    if(await dir.exists()){
      await for(final e in dir.list()){
        if(e.path.endsWith(_logName)) continue;
        try{ await e.delete(recursive:true); }catch(_){}
      }
    }
    final log = await _logFile();
    if(await log.exists()) await log.writeAsString('[]');
  }

  static String formatSize(int b){
    if(b<1024) return '$b B';
    if(b<1024*1024) return '${(b/1024).toStringAsFixed(1)} KB';
    if(b<1024*1024*1024) return '${(b/1024/1024).toStringAsFixed(1)} MB';
    return '${(b/1024/1024/1024).toStringAsFixed(2)} GB';
  }
}
