import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/duplicate_group.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/screens/export_list_detail_screen.dart';
import 'package:song_dedup/services/export_list_service.dart';
import 'package:song_dedup/services/trash_service.dart';

/// 清单列表回归测试：导出记录的保存/读取/删除，及详情页三态判定。
/// 用 ExportListService.testDir 钩子指向临时目录，不碰真机存储。
SongFile mkSong(String path, {int sizeBytes = 5000000}) {
  final name = path.split('/').last;
  return SongFile(
    id: 0,
    path: path,
    displayName: name,
    title: 'Test Song',
    artist: 'Test Artist',
    album: '',
    durationMs: 200000,
    sizeBytes: sizeBytes,
    extension: 'mp3',
    realBitrateKbps: 192,
  );
}

DuplicateGroup mkGroup(String key, List<SongFile> songs) => DuplicateGroup(
  key: key,
  songs: songs,
  displayTitle: songs.first.displayName,
  reason: 'same',
);

void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('export_list_test');
    ExportListService.testDir = () async => base;
  });

  tearDown(() async {
    ExportListService.testDir = null;
    if (await base.exists()) await base.delete(recursive: true);
  });

  group('ExportListService 保存/读取/删除', () {
    test('保存一条清单后可读回，含导出当时的全部歌曲', () async {
      final g = mkGroup('k1', [mkSong('/m/a.mp3'), mkSong('/m/b.mp3')]);
      final saved = await ExportListService.save([g]);
      expect(saved.songs.length, 2);
      expect(saved.totalSize, 10000000);
      final all = await ExportListService.loadAll();
      expect(all.length, 1);
      expect(all.first.id, saved.id);
      expect(all.first.songs.map((s) => s.path), ['/m/a.mp3', '/m/b.mp3']);
    });

    test('多次导出按时间倒序，最新在前', () async {
      await ExportListService.save([
        mkGroup('k1', [mkSong('/m/a.mp3')]),
      ]);
      await Future.delayed(const Duration(milliseconds: 5));
      await ExportListService.save([
        mkGroup('k2', [mkSong('/m/c.mp3')]),
      ]);
      final all = await ExportListService.loadAll();
      expect(all.length, 2);
      expect(all.first.songs.first.path, '/m/c.mp3');
      expect(all.last.songs.first.path, '/m/a.mp3');
    });

    test('删除一条清单后只剩其余记录', () async {
      final first = await ExportListService.save([
        mkGroup('k1', [mkSong('/m/a.mp3')]),
      ]);
      await Future.delayed(const Duration(milliseconds: 5));
      await ExportListService.save([
        mkGroup('k2', [mkSong('/m/c.mp3')]),
      ]);
      await ExportListService.delete(first.id);
      final all = await ExportListService.loadAll();
      expect(all.length, 1);
      expect(all.first.songs.first.path, '/m/c.mp3');
    });

    test('saveSongs 按歌列表保存，来源标记 delete 往返不丢', () async {
      final saved = await ExportListService.saveSongs([
        mkSong('/m/a.mp3'),
        mkSong('/m/b.mp3'),
      ], source: 'delete');
      expect(saved.source, 'delete');
      expect(saved.songs.length, 2);
      final all = await ExportListService.loadAll();
      expect(all.length, 1);
      expect(all.first.source, 'delete');
      expect(all.first.songs.map((s) => s.path), ['/m/a.mp3', '/m/b.mp3']);
    });

    test('旧记录无 source 字段时默认 manual', () {
      final list = ExportList(
        id: '7',
        savedAt: DateTime(2026, 11, 9),
        songs: [mkSong('/m/a.mp3')],
      );
      final raw = list.toJson()..remove('source');
      expect(ExportList.fromJson(raw).source, 'manual');
    });

    test('空分组保存出空歌清单，读取不崩', () async {
      final saved = await ExportListService.save([]);
      expect(saved.songs, isEmpty);
      final all = await ExportListService.loadAll();
      expect(all.length, 1);
      expect(all.first.songs, isEmpty);
    });

    test('ExportList JSON 往返不丢字段', () {
      final list = ExportList(
        id: '42',
        savedAt: DateTime(2026, 11, 9, 10, 30),
        songs: [mkSong('/m/a.mp3', sizeBytes: 12345)],
      );
      final back = ExportList.fromJson(list.toJson());
      expect(back.id, '42');
      expect(back.savedAt, DateTime(2026, 11, 9, 10, 30));
      expect(back.songs.length, 1);
      expect(back.songs.first.path, '/m/a.mp3');
      expect(back.songs.first.sizeBytes, 12345);
      expect(back.totalSize, 12345);
    });
  });

  group('buildText / buildM3u 导出格式', () {
    test('文本格式含标题、组数、每首歌名与码率', () {
      final g = mkGroup('k1', [
        mkSong('/m/a.mp3', sizeBytes: 5000000),
        mkSong('/m/b.mp3', sizeBytes: 6000000),
      ]);
      final text = ExportListService.buildText([g]);
      expect(text.contains('清聆 重复清单'), isTrue);
      expect(text.contains('共 1 组重复'), isTrue);
      expect(text.contains('a.mp3'), isTrue);
      expect(text.contains('b.mp3'), isTrue);
      expect(text.contains('/m/a.mp3'), isTrue);
    });

    test('M3U 格式以 #EXTM3U 开头，每首歌一行 EXTINF 加路径', () {
      final g = mkGroup('k1', [mkSong('/m/a.mp3')]);
      final m3u = ExportListService.buildM3u([g]);
      expect(m3u.startsWith('#EXTM3U'), isTrue);
      expect(m3u.contains('#EXTINF:200,Test Artist - Test Song'), isTrue);
      expect(m3u.contains('/m/a.mp3'), isTrue);
    });

    test('空分组导出的文本只有标题行、不崩', () {
      final text = ExportListService.buildText([]);
      expect(text.contains('共 0 组重复'), isTrue);
      expect(ExportListService.buildM3u([]).trim(), '#EXTM3U');
    });
  });

  group('songStatus 三态判定', () {
    test('原路径文件还在 → 仍在曲库（即使回收站也有旧记录）', () {
      final s = mkSong('/m/a.mp3');
      final trash = {
        '/m/a.mp3': TrashRecord(
          originalPath: '/m/a.mp3',
          trashPath: '/t/1_a.mp3',
          size: 1,
          name: 'a.mp3',
          time: DateTime.now(),
        ),
      };
      final exists = <String>{'/m/a.mp3', '/t/1_a.mp3'};
      expect(songStatus(s, trash, exists.contains), ExportSongStatus.inLibrary);
    });

    test('原路径没了、回收站记录与文件都在 → 在回收站，可恢复', () {
      final s = mkSong('/m/a.mp3');
      final trash = {
        '/m/a.mp3': TrashRecord(
          originalPath: '/m/a.mp3',
          trashPath: '/t/1_a.mp3',
          size: 1,
          name: 'a.mp3',
          time: DateTime.now(),
        ),
      };
      final exists = <String>{'/t/1_a.mp3'};
      expect(songStatus(s, trash, exists.contains), ExportSongStatus.inTrash);
    });

    test('原路径没了、回收站没记录 → 无法恢复', () {
      final s = mkSong('/m/a.mp3');
      expect(songStatus(s, {}, (_) => false), ExportSongStatus.gone);
    });

    test('回收站有记录但回收站文件没了 → 无法恢复', () {
      final s = mkSong('/m/a.mp3');
      final trash = {
        '/m/a.mp3': TrashRecord(
          originalPath: '/m/a.mp3',
          trashPath: '/t/1_a.mp3',
          size: 1,
          name: 'a.mp3',
          time: DateTime.now(),
        ),
      };
      expect(songStatus(s, trash, (_) => false), ExportSongStatus.gone);
    });
  });
}
