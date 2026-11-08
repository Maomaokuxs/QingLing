import 'package:flutter_test/flutter_test.dart';
import 'package:song_dedup/main.dart';

void main() {
  testWidgets('App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const SongDedupApp());
    expect(find.text('清聆'), findsOneWidget);
  });
  testWidgets('shows empty state', (WidgetTester tester) async {
    await tester.pumpWidget(const SongDedupApp());
    expect(find.text('发现重复歌曲'), findsOneWidget);
    expect(find.text('扫描相似歌曲'), findsOneWidget);
  });
}
