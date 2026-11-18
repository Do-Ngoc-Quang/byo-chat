import 'package:byo_chat/ui/states.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('StateCard: hiện tiêu đề, mô tả; nút chỉ có khi có action và gọi onAction', (t) async {
    var n = 0;
    Widget app(Widget w) => MaterialApp(theme: Ui.theme(), home: Scaffold(body: w));
    await t.pumpWidget(app(const StateCard(icon: Icons.search, title: 'Không tìm thấy', message: 'Không có kết quả.')));
    expect(find.text('Không tìm thấy'), findsOneWidget);
    expect(find.byKey(const Key('state-action')), findsNothing);
    await t.pumpWidget(app(StateCard(icon: Icons.error_outline, title: 'Không tải được', message: 'Thử lại.', action: 'Thử lại', onAction: () => n++)));
    await t.tap(find.byKey(const Key('state-action')));
    expect(n, 1);
  });
}
