import 'package:byo_chat/ui/new_chat_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  desktopTests();
  testWidgets('NewChatView: nhập liên hệ hiện dòng Nhắn tới và gửi đúng chuỗi; bấm Tạo nhóm và dòng gần đây', (t) async {
    String? sent;
    var group = false;
    int? picked;
    await t.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: NewChatView(
          recent: const ['An', 'Bình'],
          onSubmit: (v) => sent = v,
          onGroup: () => group = true,
          onPickRecent: (i) => picked = i,
        ),
      ),
    );
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

void desktopTests() {
  testWidgets('NewChatView Desktop: hộp thoại 480 giữa màn', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: NewChatView(recent: ['Bảo Trân'])));
    final d = find.byKey(const Key('new-chat-dialog'));
    expect(t.getSize(d).width, 480);
    expect(t.getCenter(d).dx, 640);
    expect(find.byKey(const Key('new-group')), findsOneWidget);
    expect(find.byKey(const Key('recent-0')), findsOneWidget);
  });
}
