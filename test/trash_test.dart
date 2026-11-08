import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/services/trash_service.dart';

/// 回收站逻辑回归测试：文件名碰撞、批次精确撤销、取消回滚。
/// 用 TrashService.testTrashDir 钩子指向临时目录，不碰真机存储。
void main() {
  late Directory base;
  late Directory musicDir;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('trash_test');
    musicDir = Directory('${base.path}/music')..createSync();
    TrashService.testTrashDir = () async => Directory('${base.path}/trash');
  });

  tearDown(() async {
    TrashService.testTrashDir = null;
    if (await base.exists()) await base.delete(recursive: true);
  });

  File mkSong(String name, {String sub = '', String content = 'audio'}) {
    final d = sub.isEmpty
        ? musicDir
        : (Directory('${musicDir.path}/$sub')..createSync(recursive: true));
    final f = File('${d.path}/$name');
    f.writeAsStringSync(content * 200);
    return f;
  }

  test('同名文件进回收站不互相覆盖', () async {
    final a = mkSong('track01.mp3', sub: 'album1', content: 'AAA');
    final b = mkSong('track01.mp3', sub: 'album2', content: 'BBB');
    final records = await TrashService.moveToTrash([a.path, b.path]);
    expect(records.length, 2);
    expect(records[0].trashPath == records[1].trashPath, isFalse);
    final ca = File(records[0].trashPath).readAsStringSync();
    final cb = File(records[1].trashPath).readAsStringSync();
    // 各自内容正确，没有被对方覆盖
    expect(ca.contains('AAA'), isTrue);
    expect(cb.contains('BBB'), isTrue);
    expect(ca.contains('BBB'), isFalse);
  });

  test('不存在的文件被跳过，不产生记录', () async {
    final a = mkSong('real.mp3');
    final records =
        await TrashService.moveToTrash([a.path, '/nonexistent/ghost.mp3']);
    expect(records.length, 1);
    expect(records.first.originalPath, a.path);
  });

  test('restoreLastBatch 只恢复最近一批（无时间间隔也精确）', () async {
    final a1 = mkSong('a1.mp3', content: 'A1');
    final a2 = mkSong('a2.mp3', content: 'A2');
    final b1 = mkSong('b1.mp3', content: 'B1');
    // 紧接着删两批：旧的 5 秒窗口逻辑会把两批混在一起
    await TrashService.moveToTrash([a1.path, a2.path]);
    await TrashService.moveToTrash([b1.path]);
    // 模拟原文件已被删除
    a1.deleteSync();
    a2.deleteSync();
    b1.deleteSync();

    final n = await TrashService.restoreLastBatch();
    expect(n, 1);
    expect(File(b1.path).existsSync(), isTrue);
    expect(File(a1.path).existsSync(), isFalse);
    expect(File(a2.path).existsSync(), isFalse);
    // 日志里还剩 a 组的两条记录
    final log = await TrashService.loadLog();
    expect(log.length, 2);
  });

  test('discardRecords 清掉文件与日志（取消删除回滚）', () async {
    final a = mkSong('x.mp3');
    final b = mkSong('y.mp3');
    final records = await TrashService.moveToTrash([a.path, b.path]);
    expect(records.length, 2);
    await TrashService.discardRecords(records);
    for (final r in records) {
      expect(File(r.trashPath).existsSync(), isFalse);
    }
    final log = await TrashService.loadLog();
    expect(log, isEmpty);
    // 原文件不受影响
    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isTrue);
  });

  test('batchId 写入日志并能正确解析', () async {
    final a = mkSong('z.mp3');
    final records = await TrashService.moveToTrash([a.path]);
    expect(records.first.batchId.isNotEmpty, isTrue);
    final log = await TrashService.loadLog();
    expect(log.length, 1);
    expect(log.first.batchId, records.first.batchId);
  });
}
