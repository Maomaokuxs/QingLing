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

    test('日文假名与汉字并列 → unknown（无明显多数，不拆组）', () {
      // 幾田りら：幾田=汉字 2，りら=假名 2，并列无明显多数 → unknown
      // （宁可漏过：证据不足不拆组）
      final s2 = mkSong('/b.flac', title: '幾田りら', artist: '');
      expect(SimilarityService.dominantScriptOf(s2), 'unknown');
      // 拉丁 13 字占明显多数 → latin，不受并列影响
      final s = mkSong('/a.flac', title: 'Nameless Faces', artist: '幾田りら');
      expect(SimilarityService.dominantScriptOf(s), 'latin');
    });

    test('混合脚本无明显多数 → unknown', () {
      // 汉字 2 vs 拉丁 2 并列 → unknown
      final s = mkSong('/a.flac', title: '夜曲 AB', artist: '');
      expect(SimilarityService.dominantScriptOf(s), 'unknown');
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

    test('关键词是整个歌名 → 不误拆（原版）', () {
      // 歌名本身叫《Instrumental》/《伴奏》，关键词是整个标题，
      // 前面无其他内容 → 不认作版本标注
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: 'Instrumental')),
        '原版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '伴奏')),
        '原版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '版本')),
        '原版',
      );
    });

    test('关键词在标题中间 → 不认', () {
      // "My Instrumental Song"：Instrumental 是歌名的一部分，不是版本标注
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'My Instrumental Song'),
        ),
        '原版',
      );
    });

    test('分隔符后的关键词 → 认', () {
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲 - 伴奏')),
        '伴奏',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Song - Instrumental'),
        ),
        '伴奏',
      );
    });

    test('中文关键词后缀 → 认', () {
      // 无括号、无分隔符，但关键词作后缀且前缀非空
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲中文版')),
        '中文版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '夜曲伴奏')),
        '伴奏',
      );
    });

    test('下载副本后缀 (数字) → 不是版本标记', () {
      // 系统下载重命名后缀 (1)/(2)，不是版本；三Z-STUDIO 副本案
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Wifi无处不在 (1)'),
        ),
        '原版',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Wifi无处不在 (2)'),
        ),
        '原版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '歌名[12]')),
        '原版',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '歌名（3）')),
        '原版',
      );
      // (1) 后缀不遮住真正的版本标签
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: '夜曲 (伴奏) (1)'),
        ),
        '伴奏',
      );
      // 4 位年份不是副本后缀，照常认
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Children of the Dark(2021)'),
        ),
        '2021年',
      );
    });

    test('Live / Remix / 不插电 / Demo → 各自的版本标签', () {
      // 回归：关键词表曾无 live/remix，原版/Live/Remix 全认成"原版"，
      // 元数据细分拆不开，导致不同版本被合成一组、错勾选删除。
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'TEST B Song (Live)'),
        ),
        '现场版',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'TEST B Song (Remix)'),
        ),
        '混音版',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Song (Acoustic)'),
        ),
        '不插电',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Song (Demo)'),
        ),
        'Demo',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'TEST B Song'),
        ),
        '原版',
      );
    });
  });

  group('歌手比对', () {
    test('相同歌手 → 兼容', () {
      expect(SimilarityService.artistsCompatible('周杰伦', '周杰伦'), isTrue);
    });

    test('子集人数差 >= 2x → 拆组（宁可漏过，多拆安全）', () {
      // 周杰伦 vs 周杰伦&方文山（1 vs 2，比例 2x）→ 拆
      expect(
        SimilarityService.artistsCompatible('周杰伦', '周杰伦&方文山'),
        isFalse,
      );
      // HOYO-MiX vs 幾田りら&HOYO-MiX（1 vs 2，比例 2x）→ 拆
      expect(
        SimilarityService.artistsCompatible('HOYO-MiX', '幾田りら&HOYO-MiX'),
        isFalse,
      );
    });

    test('子集人数差小 → 仍兼容（3人 vs 2人，差1，比例1.5x）', () {
      expect(
        SimilarityService.artistsCompatible(
          '周杰伦&方文山',
          '周杰伦&方文山&林迈可',
        ),
        isTrue,
      );
    });

    test('子集人数差 >= 3 → 拆组（1 vs 4）', () {
      expect(
        SimilarityService.artistsCompatible(
          '周杰伦',
          '周杰伦&方文山&林迈可&洪敬尧',
        ),
        isFalse,
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

    test('多处不同 → 不兼容（Test Artist One vs Test Artist Two）', () {
      // 回归：笔误容忍曾为短名长度/3，15 字名字容忍 5 处，
      // "One"→"Two"（3 处不同）被误判为同一歌手，导致错分组、错勾选。
      expect(
        SimilarityService.artistsCompatible(
            'Test Artist One', 'Test Artist Two'),
        isFalse,
      );
    });

    test('空/未知歌手 → 兼容（无法判断不拆）', () {
      expect(SimilarityService.artistsCompatible('', '周杰伦'), isTrue);
      expect(SimilarityService.artistsCompatible('<unknown>', '周杰伦'), isTrue);
    });
  });

  group('元数据拆组', () {
    test('原版 / Live / Remix → 拆成 3 个单首簇（TEST B 组回归）', () {
      // 三个版本各成一簇，全是单首 → subdivideByMetadata 整组丢弃，
      // 不会出现在重复列表里，也就不会被错勾选删除。
      final songs = [
        mkSong('/a.mp3', title: 'TEST B Song', artist: 'Test Artist'),
        mkSong('/b.mp3', title: 'TEST B Song (Live)', artist: 'Test Artist'),
        mkSong('/c.mp3', title: 'TEST B Song (Remix)', artist: 'Test Artist'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 3);
      expect(
        SimilarityService.subdivideByMetadata([mkGroup(songs)]),
        isEmpty,
      );
    });

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

  group('版本标记扩展（Part / 年份 / 重制 / 合唱 / 和声伴奏）', () {
    test('Part.2 vs Part.3 → 不同标签', () {
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: '欢迎来到美梦小镇！Part.2 Welcome to Dreamville!'),
        ),
        'Part2',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/b.flac', title: '欢迎来到美梦小镇！Part.3 Welcome to Dreamville!'),
        ),
        'Part3',
      );
    });

    test('Part 格式多样：Part 2 / Pt.2 / 第2部分', () {
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: 'Song Part 2')),
        'Part2',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: 'Song Pt.2')),
        'Part2',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/a.flac', title: '歌曲 第2部分')),
        'Part2',
      );
    });

    test('年份：(2021) vs 原版', () {
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Children of the Dark(2021)'),
        ),
        '2021年',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/b.flac', title: 'Children Of The Dark'),
        ),
        '原版',
      );
    });

    test('重制：Remastered vs 原版', () {
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Lonely(Remastered)'),
        ),
        '重制',
      );
      expect(
        SimilarityService.versionTagOf(mkSong('/b.flac', title: 'Lonely')),
        '原版',
      );
    });

    test('合唱：(合唱) vs 原版', () {
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: '沉默是金(合唱)'),
        ),
        '合唱',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/b.flac', title: '沉默是金'),
        ),
        '原版',
      );
    });

    test('和声伴奏 vs 伴奏 → 不同标签（精确匹配，不用子串）', () {
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: '拂晓 Proi Proi（和声伴奏）(伴奏)'),
        ),
        '和声伴奏',
      );
      expect(
        SimilarityService.versionTagOf(
          mkSong('/b.flac', title: '拂晓 Proi Proi（伴奏）(伴奏)'),
        ),
        '伴奏',
      );
    });

    test('组合标签：Part 2 (Remastered) → Part2+重制', () {
      expect(
        SimilarityService.versionTagOf(
          mkSong('/a.flac', title: 'Song Part 2 (Remastered)'),
        ),
        'Part2+重制',
      );
    });
  });

  group('导出清单 6 组误分组回归', () {
    test('Beethoven：9人版 vs 钢琴二人版 → 拆组', () {
      final songs = [
        mkSong('/a.flac',
            title: "Beethoven's 5 Secrets",
            artist:
                'The Piano Guys&Lyceum Philharmonic at American Heritage School&Ludwig van Beethoven&Ryan B. Tedder&Steven Sharp Nelson&Al Van der beek&Kayson Brown&Julie Ann Nelson&John Nelson'),
        mkSong('/b.flac',
            title: "Beethoven's 5 Secrets",
            artist:
                'The Piano Guys&Lyceum Philharmonic at American Heritage School&Ludwig van Beethoven&Ryan B. Tedder&Steven Sharp Nelson&Al Van der beek&Kayson Brown&Julie Ann Nelson&John Nelson'),
        mkSong('/c.flac',
            title: "Beethoven's 5 Secrets", artist: 'The Piano Guys'),
        mkSong('/d.flac',
            title: "Beethoven's 5 Secrets", artist: 'The Piano Guys'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 2);
    });

    test('沉默是金：独唱 vs 合唱 → 拆组', () {
      final songs = [
        mkSong('/a.flac', title: '沉默是金', artist: '张国荣'),
        mkSong('/b.flac', title: '沉默是金', artist: '张国荣'),
        mkSong('/c.flac', title: '沉默是金(合唱)', artist: '许冠杰&张国荣'),
        mkSong('/d.flac', title: '沉默是金(合唱)', artist: '许冠杰&张国荣'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 2);
    });

    test('美梦小镇：Part.2 vs Part.3 → 拆组', () {
      final songs = [
        mkSong('/a.flac', title: '欢迎来到美梦小镇！Part.2 Welcome to Dreamville!'),
        mkSong('/b.flac', title: '欢迎来到美梦小镇！Part.2 Welcome to Dreamville!'),
        mkSong('/c.flac', title: '欢迎来到美梦小镇！Part.3 Welcome to Dreamville!'),
        mkSong('/d.flac', title: '欢迎来到美梦小镇！Part.3 Welcome to Dreamville!'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 2);
    });

    test('Children of the Dark：2021 vs 原版 → 拆组', () {
      final songs = [
        mkSong('/a.flac', title: 'Children of the Dark(2021)'),
        mkSong('/b.flac', title: 'Children of the Dark(2021)'),
        mkSong('/c.flac', title: 'Children Of The Dark'),
        mkSong('/d.flac', title: 'Children Of The Dark'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 2);
    });

    test('Lonely：Remastered vs 原版 → 拆组', () {
      final songs = [
        mkSong('/a.flac', title: 'Lonely(Remastered)'),
        mkSong('/b.flac', title: 'Lonely(Remastered)'),
        mkSong('/c.flac', title: 'Lonely'),
        mkSong('/d.flac', title: 'Lonely'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 2);
    });

    test('拂晓：和声伴奏 vs 伴奏 → 拆组', () {
      final songs = [
        mkSong('/a.flac', title: '拂晓 Proi Proi（和声伴奏）(伴奏)'),
        mkSong('/b.flac', title: '拂晓 Proi Proi（和声伴奏）(伴奏)'),
        mkSong('/c.flac', title: '拂晓 Proi Proi（伴奏）(伴奏)'),
        mkSong('/d.flac', title: '拂晓 Proi Proi（伴奏）(伴奏)'),
      ];
      expect(SimilarityService.clusterByMetadata(songs).length, 2);
    });
  });
}
