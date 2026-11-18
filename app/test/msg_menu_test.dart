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

  testWidgets('MsgMenuPopover: đặt dưới bong bóng, căn mép phải với tin của mình', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const anchor = Rect.fromLTWH(700, 300, 300, 40);
    await t.pumpWidget(
      MaterialApp(theme: Ui.theme(), home: const MsgMenuPopover(anchor: anchor, mine: true)),
    );
    final r = t.getRect(find.byKey(const Key('msg-popover')));
    expect(r.right, anchor.right);
    expect(r.top, anchor.bottom + 8);
    expect(r.width, 220);
    expect(find.text('Xóa'), findsOneWidget);
  });
}
