import 'package:byo_chat/ui/profile_setup_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ProfileSetupView: Hoàn tất tắt khi chưa có tên; có tên thì gọi onDone với tên đã cắt khoảng trắng', (t) async {
    String? done;
    await t.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: ProfileSetupView(onDone: (v) => done = v),
      ),
    );
    expect(t.widget<FilledButton>(find.byKey(const Key('profile-done'))).onPressed, isNull);
    await t.enterText(find.byKey(const Key('profile-name')), '  Nguyễn Bảo ');
    await t.pump();
    expect(find.text('B'), findsOneWidget);
    await t.tap(find.byKey(const Key('profile-done')));
    expect(done, 'Nguyễn Bảo');
  });
}
