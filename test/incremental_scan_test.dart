import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/duplicate_group.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/scan_cache.dart';
import 'package:song_dedup/services/similarity_service.dart';

SongFile mk({
  required String path,
  String title = '',
  String artist = '',
  int durationMs = 0,
  int sizeBytes = 1000000,
  String ext = 'mp3',
  int dateModified = 100,
}) {
  final name = path.split('/').last;
  return SongFile(
    id: 0,
    path: path,
    displayName: name,
    title: title,
    artist: artist,
    album: '',
    durationMs: durationMs,
    sizeBytes: sizeBytes,
    extension: ext,
    dateModified: dateModified,
  );
}

DuplicateGroup grp(List<SongFile> songs, {String reason = '标题/歌手一致'}) {
  return DuplicateGroup(
    key: 'test::${songs.first.path}',
    songs: songs,
    displayTitle: songs.first.title,
    reason: reason,
  );
}

void main() {
  group('groupIncremental', () {
    test('新增文件和旧组里的文件重复 → 合并进旧组', () async {
      final oldA = mk(
          path: '/old/夜曲.flac',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'flac',
          sizeBytes: 30000000);
      final oldA2 = mk(
          path: '/old/夜曲.mp3',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 211000,
          ext: 'mp3',
          sizeBytes: 8000000);
      final oldB = mk(
          path: '/old/晴天.mp3', title: '晴天', artist: '周杰伦', durationMs: 260000);
      final newN = mk(
          path: '/new/夜曲.m4a',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'm4a',
          sizeBytes: 9000000);

      final result = await SimilarityService.groupIncremental(
        newSongs: [newN],
        oldSongs: [oldA, oldA2, oldB],
        oldGroups: [grp([oldA, oldA2])],
        enableFingerprint: false,
      );

      expect(result.length, 1);
      expect(
        result.first.songs.map((s) => s.path).toSet(),
        {'/old/夜曲.flac', '/old/夜曲.mp3', '/new/夜曲.m4a'},
      );
    });

    test('新增文件和未分组旧文件重复 → 合并（含旧歌）', () async {
      final oldU = mk(
          path: '/old/晴天.mp3', title: '晴天', artist: '周杰伦', durationMs: 260000);
      final newN1 = mk(
          path: '/new/晴天.flac',
          title: '晴天',
          artist: '周杰伦',
          durationMs: 260000,
          ext: 'flac',
          sizeBytes: 30000000);
      final newN2 = mk(
          path: '/new/晴天.m4a',
          title: '晴天',
          artist: '周杰伦',
          durationMs: 261000,
          ext: 'm4a',
          sizeBytes: 9000000);

      final result = await SimilarityService.groupIncremental(
        newSongs: [newN1, newN2],
        oldSongs: [oldU],
        oldGroups: [],
        enableFingerprint: false,
      );

      expect(result.length, 1);
      expect(
        result.first.songs.map((s) => s.path).toSet(),
        {'/old/晴天.mp3', '/new/晴天.flac', '/new/晴天.m4a'},
      );
    });

    test('新增文件互为重复 → 新组，旧歌不掺入', () async {
      final oldX = mk(
          path: '/old/完全不同.mp3',
          title: '完全不同',
          artist: '别人',
          durationMs: 100000);
      final newN1 = mk(
          path: '/new/夜曲.flac',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'flac',
          sizeBytes: 30000000);
      final newN2 = mk(
          path: '/new/夜曲.mp3',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 211000,
          ext: 'mp3',
          sizeBytes: 8000000);

      final result = await SimilarityService.groupIncremental(
        newSongs: [newN1, newN2],
        oldSongs: [oldX],
        oldGroups: [],
        enableFingerprint: false,
      );

      expect(result.length, 1);
      expect(
        result.first.songs.map((s) => s.path).toSet(),
        {'/new/夜曲.flac', '/new/夜曲.mp3'},
      );
    });

    test('新增文件无匹配 → 旧组原样保留', () async {
      final oldA = mk(
          path: '/old/夜曲.flac',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'flac',
          sizeBytes: 30000000);
      final oldA2 = mk(
          path: '/old/夜曲.mp3',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 211000,
          ext: 'mp3',
          sizeBytes: 8000000);
      final newN = mk(
          path: '/new/完全不同.mp3',
          title: '完全不同',
          artist: '别人',
          durationMs: 100000);

      final result = await SimilarityService.groupIncremental(
        newSongs: [newN],
        oldSongs: [oldA, oldA2],
        oldGroups: [grp([oldA, oldA2])],
        enableFingerprint: false,
      );

      expect(result.length, 1);
      expect(
        result.first.songs.map((s) => s.path).toSet(),
        {'/old/夜曲.flac', '/old/夜曲.mp3'},
      );
    });

    test('无新增 → 旧组原样返回', () async {
      final oldA = mk(
          path: '/old/夜曲.flac',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'flac');
      final oldA2 = mk(
          path: '/old/夜曲.mp3',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 211000,
          ext: 'mp3');
      final oldGroups = [grp([oldA, oldA2])];

      final result = await SimilarityService.groupIncremental(
        newSongs: [],
        oldSongs: [oldA, oldA2],
        oldGroups: oldGroups,
        enableFingerprint: false,
      );

      expect(identical(result, oldGroups), isTrue);
    });
  });

  group('ScanCache.splitNewVsOld', () {
    test('新增 / 变更 / 未变分类', () {
      final current = [
        mk(path: '/a/1.mp3', dateModified: 100, sizeBytes: 1000),
        mk(path: '/a/2.mp3', dateModified: 200, sizeBytes: 2000),
        mk(path: '/a/3.mp3', dateModified: 300, sizeBytes: 3000),
      ];
      final cached = [
        mk(path: '/a/1.mp3', dateModified: 100, sizeBytes: 1000),
        mk(path: '/a/2.mp3', dateModified: 201, sizeBytes: 2000),
        mk(path: '/a/4.mp3', dateModified: 400, sizeBytes: 4000),
      ];

      final r = ScanCache.splitNewVsOld(current, cached);

      expect(r.changed.map((s) => s.path).toSet(), {'/a/2.mp3', '/a/3.mp3'});
      expect(r.unchanged.map((s) => s.path).toSet(), {'/a/1.mp3'});
    });
  });

  group('ScanCache.refreshGroups', () {
    test('删除与变更剔除，<2 首整组丢弃', () {
      final a = mk(path: '/a/A.mp3');
      final b = mk(path: '/a/B.mp3');
      final c = mk(path: '/a/C.mp3');
      final d = mk(path: '/a/D.mp3');
      // D 已删除（不在 byPath），B 已变更
      final byPath = {'/a/A.mp3': a, '/a/B.mp3': b, '/a/C.mp3': c};
      final groups = [
        grp([a, b]),
        grp([c, d]),
      ];

      final result = ScanCache.refreshGroups(groups, byPath, {'/a/B.mp3'});

      expect(result, isEmpty);
    });

    test('刷新后用新鲜 SongFile 对象，组保留', () {
      final oldA = mk(path: '/a/A.mp3', title: '旧标题');
      final oldB = mk(path: '/a/B.mp3');
      final oldC = mk(path: '/a/C.mp3');
      final freshA = mk(path: '/a/A.mp3', title: '新标题');
      final byPath = {
        '/a/A.mp3': freshA,
        '/a/B.mp3': oldB,
        '/a/C.mp3': oldC,
      };

      final result = ScanCache.refreshGroups(
        [grp([oldA, oldB, oldC])],
        byPath,
        {},
      );

      expect(result.length, 1);
      expect(result.first.songs.first.title, '新标题');
      expect(identical(result.first.songs.first, freshA), isTrue);
    });
  });

  group('增量全链路', () {
    test('重扫：旧组 + 新增副本 → 新增并入旧组，删除的歌剔除', () async {
      // 上次缓存：A、B 一组，C 未分组
      final cacheA = mk(
          path: '/a/A.flac',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'flac',
          sizeBytes: 30000000,
          dateModified: 100);
      final cacheB = mk(
          path: '/a/B.mp3',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 211000,
          ext: 'mp3',
          sizeBytes: 8000000,
          dateModified: 100);
      // 本次扫描：A、B 未变，C 已删除，N 新增（A 的副本）
      final curA = mk(
          path: '/a/A.flac',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'flac',
          sizeBytes: 30000000,
          dateModified: 100);
      final curB = mk(
          path: '/a/B.mp3',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 211000,
          ext: 'mp3',
          sizeBytes: 8000000,
          dateModified: 100);
      final curN = mk(
          path: '/a/N.m4a',
          title: '夜曲',
          artist: '周杰伦',
          durationMs: 210000,
          ext: 'm4a',
          sizeBytes: 9000000,
          dateModified: 500);
      final cachedFiles = [
        mk(path: '/a/A.flac', dateModified: 100, sizeBytes: 30000000),
        mk(path: '/a/B.mp3', dateModified: 100, sizeBytes: 8000000),
        mk(path: '/a/C.mp3', dateModified: 100, sizeBytes: 5000000),
      ];

      final diff = ScanCache.splitNewVsOld(
        [curA, curB, curN],
        cachedFiles,
      );
      expect(diff.changed.map((s) => s.path).toList(), ['/a/N.m4a']);
      expect(diff.unchanged.length, 2);

      final oldGroups = ScanCache.refreshGroups(
        [grp([cacheA, cacheB])],
        {'/a/A.flac': curA, '/a/B.mp3': curB, '/a/N.m4a': curN},
        {'/a/N.m4a'},
      );
      expect(oldGroups.length, 1);

      final result = await SimilarityService.groupIncremental(
        newSongs: diff.changed,
        oldSongs: diff.unchanged,
        oldGroups: oldGroups,
        enableFingerprint: false,
      );

      expect(result.length, 1);
      expect(
        result.first.songs.map((s) => s.path).toSet(),
        {'/a/A.flac', '/a/B.mp3', '/a/N.m4a'},
      );
    });
  });

  group('缓存分组版本', () {
    test('旧缓存（无版本号）/ 旧版本 → 失效，全量重扫', () {
      // 回归：增量扫描曾无视分组逻辑改动，旧的错分组永远复用（一次错、次次错）。
      expect(ScanCache.isGroupingVersionCurrent({}), isFalse);
      expect(
        ScanCache.isGroupingVersionCurrent({'groupingVersion': 1}),
        isFalse,
      );
      expect(
        ScanCache.isGroupingVersionCurrent({
          'groupingVersion': SimilarityService.groupingVersion,
        }),
        isTrue,
      );
    });
  });
}
