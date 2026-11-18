import 'package:byo_chat/ui/contact_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ContactView: hiện tên, trạng thái chưa có tệp, nút quay lại gọi onBack', (t) async {
    var back = false;
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: ContactView(name: 'An Nguyễn', onBack: () => back = true)));
    expect(find.text('An Nguyễn'), findsOneWidget);
    expect(find.byKey(const Key('contact-media-empty')), findsOneWidget);
    expect(find.text('Chặn người dùng'), findsOneWidget);
    await t.tap(find.byKey(const Key('contact-back')));
    expect(back, isTrue);
  });
}
