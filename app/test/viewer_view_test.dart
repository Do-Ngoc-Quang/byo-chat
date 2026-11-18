import 'package:byo_chat/ui/viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ViewerView: hiện người gửi, thời gian, chỉ số; nút đóng gọi onClose', (t) async {
    var closed = false;
    await t.pumpWidget(
      MaterialApp(
        home: ViewerView(sender: 'Minh Anh', when: 'Hôm nay, 09:41', index: 3, total: 12, onClose: () => closed = true),
      ),
    );
    expect(find.text('Minh Anh'), findsOneWidget);
    expect(find.text('Hôm nay, 09:41 · 3 / 12'), findsOneWidget);
    await t.tap(find.byKey(const Key('viewer-close')));
    expect(closed, isTrue);
  });
}
