import 'package:byo_chat/ui/new_chat_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('NewChatView: nhập liên hệ hiện dòng Nhắn tới và gửi đúng chuỗi; bấm Tạo nhóm và dòng gần đây', (t) async {
    String? sent;
    var group = false;
    int? picked;
    await t.pumpWidget(MaterialApp(
      theme: Ui.theme(),
      home: NewChatView(recent: const ['An', 'Bình'], onSubmit: (v) => sent = v, onGroup: () => group = true, onPickRecent: (i) => picked = i),
    ));
    expect(find.byKey(const Key('peer-ok')), findsNothing);
    await t.enterText(find.byKey(const Key('peer-field')), '+84912345678');
    await t.pump();
    expect(find.text('Nhắn tới +84912345678'), findsOneWidget);
    await t.tap(find.byKey(const Key('peer-ok')));
    expect(sent, '+84912345678');
    await t.tap(find.byKey(const Key('new-group')));
    expect(group, isTrue);
    await t.tap(find.byKey(const Key('recent-1')));
    expect(picked, 1);
  });
}
