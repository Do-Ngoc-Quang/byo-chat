import 'package:byo_chat/ui/msg_menu.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MsgMenuView: tin của mình có Chỉnh sửa/Xóa, tin người khác không; Sao chép gọi onCopy', (t) async {
    var copied = false;
    Widget app(bool mine) => MaterialApp(
      theme: Ui.theme(),
      home: MsgMenuView(text: 'Chào', mine: mine, onCopy: () => copied = true),
    );
    await t.pumpWidget(app(true));
    expect(find.text('Xóa'), findsOneWidget);
    expect(find.text('Chỉnh sửa'), findsOneWidget);
    await t.tap(find.byKey(const Key('msg-copy')));
    expect(copied, isTrue);
    await t.pumpWidget(app(false));
    expect(find.text('Xóa'), findsNothing);
    expect(find.text('Sao chép'), findsOneWidget);
  });
}
