import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/duplicate_group.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/screens/dir_stats_screen.dart';

SongFile mk(String path, {int sizeBytes = 1000000}) {
  final name = path.split('/').last;
  return SongFile(
    id: 0,
    path: path,
    displayName: name,
    title: 'Test',
    artist: 'A',
    album: '',
    durationMs: 200000,
    sizeBytes: sizeBytes,
    extension: 'flac',
  );
}

/// 两组重复：k1 两首（40MB + 60MB），k2 一首（10MB），重复共 110MB。
List<DuplicateGroup> testGroups() => [
      DuplicateGroup(
        key: 'k1',
        displayTitle: 'Song A',
        reason: '标题/歌手一致',
        songs: [
          mk('/storage/emulated/0/Music/a.flac', sizeBytes: 40000000),
          mk('/storage/emulated/0/Music/__TEST__/a2.flac',
              sizeBytes: 60000000),
        ],
      ),
      DuplicateGroup(
        key: 'k2',
        displayTitle: 'Song B',
        reason: '标题/歌手一致',
        songs: [
          mk('/storage/emulated/0/Music/__TEST__/b.flac',
              sizeBytes: 10000000),
        ],
      ),
    ];

void main() {
  testWidgets('目录统计页：按目录分组列出文件数与占用', (tester) async {
    final groups = testGroups();
    await tester.pumpWidget(
      MaterialApp(home: DirStatsScreen(groups: groups)),
    );
    await tester.pumpAndSettle();

    expect(find.text('目录统计'), findsOneWidget);
    // /Music/__TEST__ 有 2 个文件、70MB，排第一；/Music 1 个、40MB
    expect(find.text('/storage/emulated/0/Music/__TEST__'), findsOneWidget);
    expect(find.text('/storage/emulated/0/Music'), findsOneWidget);
    expect(find.text('2 个重复文件 · 占用 66.8 MB'), findsOneWidget);
    expect(find.text('1 个重复文件 · 占用 38.1 MB'), findsOneWidget);
  });

  testWidgets('目录统计页：无分组时显示暂无重复文件', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DirStatsScreen(groups: [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无重复文件'), findsOneWidget);
  });

  testWidgets('目录统计页：饼图展示重复占用占比', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DirStatsScreen(
            groups: testGroups(), totalBytes: 200 * 1024 * 1024),
      ),
    );
    await tester.pumpAndSettle();

    // 圆环图：重复文件共 110000000 字节 = 104.9 MB，占 200.0 MB 的 52.5%
    // 百分比由画布绘制，图例只剩名称；底部一行给全部与重复的大小
    expect(find.text('重复歌曲'), findsOneWidget);
    expect(find.text('其他歌曲'), findsOneWidget);
    expect(find.text('全部歌曲共 200.0 MB，其中重复歌曲 104.9 MB'),
        findsOneWidget);
  });

  testWidgets('目录统计页：无总字节数时不显示饼图', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: DirStatsScreen(groups: testGroups())),
    );
    await tester.pumpAndSettle();

    expect(find.text('重复歌曲'), findsNothing);
    expect(find.text('其他歌曲'), findsNothing);
  });
}
