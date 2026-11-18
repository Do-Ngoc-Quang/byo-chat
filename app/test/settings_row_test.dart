import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SettingsRow: cao tối thiểu 56, bấm được, dòng nguy hiểm không có mũi tên', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SettingsRow(key: const Key('a'), icon: Icons.cloud_outlined, title: 'Sao lưu', subtitle: 'Mô tả', onTap: () => taps++),
          const SettingsRow(key: Key('b'), icon: Icons.logout, title: 'Đăng xuất', danger: true),
        ]),
      ),
    ));
    expect(tester.getSize(find.byKey(const Key('a'))).height, greaterThanOrEqualTo(56));
    await tester.tap(find.byKey(const Key('a')));
    expect(taps, 1);
    expect(find.descendant(of: find.byKey(const Key('a')), matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('b')), matching: find.byIcon(Icons.chevron_right)), findsNothing);
  });
}
