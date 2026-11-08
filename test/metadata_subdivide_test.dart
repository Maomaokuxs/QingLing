import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/models/duplicate_group.dart';
import 'package:song_dedup/models/song_file.dart';
import 'package:song_dedup/services/similarity_service.dart';

SongFile mkSong(
  String path, {
  String title = '',
  String artist = '',
  String displayName = '',
}) =>
    SongFile(
      id: 0,
      path: path,
      displayName: displayName.isNotEmpty ? displayName : path.split('/').last,
      title: title.isNotEmpty ? title : path.split('/').last,
      artist: artist,
      album: '',
      durationMs: 200000,
      sizeBytes: 5000000,
      extension: 'flac',
    );

DuplicateGroup mkGroup(List<SongFile> songs) => DuplicateGroup(
      key: 'test::${songs.map((s) => s.path).join('|')}',
      songs: songs,
      displayTitle: songs.first.title,
      reason: '标题/歌手一致',
    );

void main() {
  group('文字脚本检测', () {
    test('纯英文 → latin', () {
      final s = mkSong('/a.flac', title: 'WHITE NIGHT', artist: 'HOYO-MiX');
      expect(SimilarityService.dominantScriptOf(s), 'latin');
    });

    test('韩文歌手 + 英文标题，谚文计入统计', () {
      // 주영（谚文 2 字）+ WHITE NIGHT + HOYO-MiX（拉丁 17 字）→ 拉丁占多
      final s = mkSong('/a.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX');
      expect(SimilarityService.dominantScriptOf(s), 'latin');
    });

    test('日文假名 → kana（假名优先于汉字）', () {
      // 幾田りら：幾田=汉字 2，りら=假名 2，并列时假名优先
      final s = mkSong('/a.flac', title: 'Nameless Faces', artist: '幾田りら');
      // 拉丁 13 字占多 → latin；用纯日文标题验证并列规则
      final s2 = mkSong('/b.flac', title: '幾田りら', artist: '');
      expect(SimilarityService.dominantScriptOf(s2), 'kana');
      expect(SimilarityService.dominantScriptOf(s), 'latin');
    });

    test('纯中文 → han', () {
      final s = mkSong('/a.flac', title: '若我不曾见过太阳', artist: '知更鸟');
      expect(SimilarityService.dominantScriptOf(s), 'han');
    });

    test('纯韩文 → hangul', () {
      final s = mkSong('/a.flac', title: '노래', artist: '주영');
      expect(SimilarityService.dominantScriptOf(s), 'hangul');
    });

    test('无脚本字符 → unknown', () {
      final s = mkSong('/a.flac', title: '123', artist: '', displayName: '123');
      expect(SimilarityService.dominantScriptOf(s), 'unknown');
    });

    test('括号英文标注不影响脚本：夜曲 (Remastered) → han', () {
      final s = mkSong('/a.flac', title: '夜曲 (Remastered)', artist: '');
      expect(SimilarityService.dominantScriptOf(s), 'han');
    });
  });

  group('版本关键词检测', () {
    test('无关键词 → 原版', () {
      final s = mkSong('/a.flac', title: 'WHITE NIGHT');
      expect(SimilarityService.versionTagOf(s), '原版');
    });

    test('伴奏关键词 → 伴奏', () {
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲 (伴奏)')),
        '伴奏',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Song (Instrumental)'),
        ),
        '伴奏',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Song (Off Vocal)'),
        ),
        '伴奏',
      );
    });

    test('听障关键词 → 听障', () {
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲 低频听障版')),
        '听障',
      );
    });

    test('语言版关键词 → 对应标签', () {
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲 中文版')),
        '中文版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲 日文版')),
        '日文版',
      );
    });

    test('inst 不误伤 Instinct', () {
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: 'Instinct')),
        '原版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: 'Song (Inst.)')),
        '伴奏',
      );
    });

    test('文件名里的关键词也生效', () {
      final s = mkSong(
        '/a.flac',
        title: 'Nameless Faces',
        displayName: 'HOYO-MiX - Nameless Faces (低频听障版).flac',
      );
      expect(SimilarityService.versionTagOf(s), '听障');
    });
  });

  group('歌手比对', () {
    test('相同歌手 → 兼容', () {
      expect(SimilarityService.artistsCompatible('周杰伦', '周杰伦'), isTrue);
    });

    test('包含关系不误拆：周杰伦 vs 周杰伦&方文山', () {
      expect(
        SimilarityService.artistsCompatible('周杰伦', '周杰伦&方文山'),
        isTrue,
      );
      expect(
        SimilarityService.artistsCompatible('HOYO-MiX', '幾田りら&HOYO-MiX'),
        isTrue,
      );
    });

    test('完全不同歌手 → 不兼容', () {
      expect(
        SimilarityService.artistsCompatible('주영&HOYO-MiX', '西山晃世&HOYO-MiX'),
        isFalse,
      );
    });

    test('一字笔误 → 兼容（周杰伦 vs 周杰轮）', () {
      expect(SimilarityService.artistsCompatible('周杰伦', '周杰轮'), isTrue);
    });

    test('空/未知歌手 → 兼容（无法判断不拆）', () {
      expect(SimilarityService.artistsCompatible('', '周杰伦'), isTrue);
      expect(SimilarityService.artistsCompatible('<unknown>', '周杰伦'), isTrue);
    });
  });

  group('元数据拆组', () {
    test('不同歌手拆组：WHITE NIGHT 韩文版 vs 中文版', () {
      final songs = [
        mkSong('/a.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
        mkSong('/b.flac', title: 'WHITE NIGHT', artist: '西山晃世&HOYO-MiX'),
      ];
      final clusters = SimilarityService.clusterByMetadata(songs);
      expect(clusters.length, 2);
    });

    test('伴奏 vs 原版拆组', () {
      final songs = [
        mkSong('/a.flac', title: '夜曲'),
        mkSong('/b.flac', title: '夜曲 (伴奏)'),
      ];
      final clusters = SimilarityService.clusterByMetadata(songs);
      expect(clusters.length, 2);
    });

    test('同歌手同版本不拆组', () {
      final songs = [
        mkSong('/a.flac', title: '夜曲', artist: '周杰伦'),
        mkSong('/b.flac', title: '夜曲', artist: '周杰伦'),
      ];
      final clusters = SimilarityService.clusterByMetadata(songs);
      expect(clusters.length, 1);
    });

    test('拆出组 reason=同名不同版本 且 noAutoSelect', () {
      // 2+2：两簇都 >= 2，拆组路径仍生效
      final songs = [
        mkSong('/a.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
        mkSong('/b.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
        mkSong('/c.flac', title: 'WHITE NIGHT', artist: '西山晃世&HOYO-MiX'),
        mkSong('/d.flac', title: 'WHITE NIGHT', artist: '西山晃世&HOYO-MiX'),
      ];
      final out = SimilarityService.subdivideByMetadata([mkGroup(songs)]);
      expect(out.length, 2);
      final split = out.where((g) => g.reason == '同名不同版本');
      expect(split.length, 1);
      expect(split.first.noAutoSelect, isTrue);
      // 原组保留原 reason
      expect(out.where((g) => g.reason == '标题/歌手一致').length, 1);
    });

    test('2 首歌拆成两个单首簇后，输出为空', () {
      final songs = [
        mkSong('/a.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
        mkSong('/b.flac', title: 'WHITE NIGHT', artist: '西山晃世&HOYO-MiX'),
      ];
      final out = SimilarityService.subdivideByMetadata([mkGroup(songs)]);
      expect(out, isEmpty);
    });

    test('拆出簇只有 1 首时丢弃，只保留 >= 2 的簇', () {
      // 2 兼容 + 1 单首：单首簇丢弃，只剩原组
      final songs = [
        mkSong('/a.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
        mkSong('/b.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
        mkSong('/c.flac', title: 'WHITE NIGHT', artist: '西山晃世&HOYO-MiX'),
      ];
      final out = SimilarityService.subdivideByMetadata([mkGroup(songs)]);
      expect(out.length, 1);
      expect(out.first.songs.length, 2);
      expect(out.first.reason, '标题/歌手一致');
    });

    test('单首输入组直接丢弃', () {
      final songs = [
        mkSong('/a.flac', title: 'WHITE NIGHT', artist: '주영&HOYO-MiX'),
      ];
      final out = SimilarityService.subdivideByMetadata([mkGroup(songs)]);
      expect(out, isEmpty);
    });
  });

  group('feat. 歌手检测', () {
    test('feat. 歌手不同 → 拆组', () {
      final songs = [
        mkSong('/a.flac',
            title: '可愛くてごめん (feat. 星乃夢奈)', artist: 'HoneyWorks'),
        mkSong('/b.flac',
            title: '可愛くてごめん (feat. 星乃夢奈)', artist: 'HoneyWorks'),
        mkSong('/c.flac',
            title: '可愛くてごめん (feat. 早見沙織)', artist: 'HoneyWorks'),
        mkSong('/d.flac',
            title: '可愛くてごめん (feat. 早見沙織)', artist: 'HoneyWorks'),
      ];
      final clusters = SimilarityService.clusterByMetadata(songs);
      expect(clusters.length, 2);
      final out = SimilarityService.subdivideByMetadata([mkGroup(songs)]);
      expect(out.length, 2);
      expect(out.where((g) => g.reason == '同名不同版本').length, 1);
    });

    test('都无 feat. → 不拆组', () {
      final songs = [
        mkSong('/a.flac', title: '可愛くてごめん', artist: 'HoneyWorks'),
        mkSong('/b.flac', title: '可愛くてごめん', artist: 'HoneyWorks'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 1);
    });

    test('feat. 歌手相同 → 不拆组', () {
      final songs = [
        mkSong('/a.flac',
            title: '可愛くてごめん (feat. 星乃夢奈)', artist: 'HoneyWorks'),
        mkSong('/b.flac',
            title: '可愛くてごめん (feat. 星乃夢奈)', artist: 'HoneyWorks'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 1);
    });

    test('一首有 feat. 一首没有 → 拆组', () {
      final a = mkSong('/a.flac',
          title: '可愛くてごめん (feat. 星乃夢奈)', artist: 'HoneyWorks');
      final b = mkSong('/b.flac', title: '可愛くてごめん', artist: 'HoneyWorks');
      expect(SimilarityService.featCompatible(a, b), isFalse);
    });

    test('feat. 格式多样：featuring / ft. / feat 无点都能提取', () {
      final a = mkSong('/a.flac',
          title: 'Song featuring Jane', artist: 'Band');
      final b = mkSong('/b.flac', title: 'Song ft. John', artist: 'Band');
      final c = mkSong('/c.flac', title: 'Song feat Jane', artist: 'Band');
      expect(SimilarityService.featArtistsOf(a), {'jane'});
      expect(SimilarityService.featArtistsOf(b), {'john'});
      expect(SimilarityService.featCompatible(a, c), isTrue);
    });

    test('feat. 多人用 & 分隔，集合比对', () {
      final a = mkSong('/a.flac',
          title: 'Song (feat. A & B)', artist: 'Band');
      final b = mkSong('/b.flac',
          title: 'Song (feat. B & A)', artist: 'Band');
      final c = mkSong('/c.flac', title: 'Song (feat. A)', artist: 'Band');
      expect(SimilarityService.featCompatible(a, b), isTrue);
      expect(SimilarityService.featCompatible(a, c), isFalse);
    });

    test('文件名里的 feat. 也能提取，扩展名不混入名字', () {
      final a = mkSong('/a.flac',
          title: '',
          artist: 'HoneyWorks',
          displayName: '可愛くてごめん (feat. 星乃夢奈).flac');
      expect(SimilarityService.featArtistsOf(a), {'星乃夢奈'});
    });
  });
}
