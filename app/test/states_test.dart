import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/ui/states.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('StateCard: hiện tiêu đề, mô tả; nút chỉ có khi có action và gọi onAction', (t) async {
    var n = 0;
    Widget app(Widget w) => MaterialApp(
      theme: Ui.theme(),
      home: Scaffold(body: w),
    );
    await t.pumpWidget(app(const StateCard(icon: Icons.search, title: 'Không tìm thấy', message: 'Không có kết quả.')));
    expect(find.text('Không tìm thấy'), findsOneWidget);
    expect(find.byKey(const Key('state-action')), findsNothing);
    await t.pumpWidget(
      app(StateCard(icon: Icons.error_outline, title: 'Không tải được', message: 'Thử lại.', action: 'Thử lại', onAction: () => n++)),
    );
    await t.tap(find.byKey(const Key('state-action')));
    expect(n, 1);
  });

  testWidgets('StatusBanner: Desktop cao 40, điện thoại cao 36', (t) async {
    addTearDown(t.view.reset);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1280, 800);
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: const Scaffold(body: StatusBanner('Đang chờ kết nối'))));
    expect(t.getSize(find.byType(StatusBanner)).height, 40);
    t.view.physicalSize = const Size(400, 800);
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(StatusBanner)).height, 36);
  });

  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop States', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const items = [
      ('Chưa có cuộc trò chuyện', 'Bắt đầu bằng cách nhắn tin cho ai đó.', Icons.chat_bubble_outline, 'Soạn tin mới'),
      ('Không tìm thấy', 'Không có kết quả cho “thiết kế”.', Icons.search, null),
      ('Không tải được', 'Đã có lỗi xảy ra. Vui lòng thử lại.', Icons.error_outline, 'Thử lại'),
      ('Đang chờ kết nối', 'Tin nhắn sẽ được gửi khi có mạng trở lại.', Icons.wifi_off, null),
      ('Đang cập nhật…', 'Đang tải các tin nhắn mới.', Icons.sync, null),
      ('Bạn đã được đăng xuất', 'Phiên đăng nhập đã hết hạn.', Icons.lock_outline, 'Đăng nhập lại'),
    ];
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: Ui.theme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: Ui.surfaceAlt,
            body: Center(
              child: SizedBox(
                width: 960,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Trạng thái dùng chung', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: Ui.text)),
                    const SizedBox(height: 16),
                    const StatusBanner('Đang chờ kết nối'),
                    const SizedBox(height: 20),
                    for (var r = 0; r < 2; r++) ...[
                      if (r > 0) const SizedBox(height: 16),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var c = 0; c < 3; c++) ...[
                              if (c > 0) const SizedBox(width: 16),
                              Expanded(
                                child: StateCard(
                                  icon: items[r * 3 + c].$3,
                                  title: items[r * 3 + c].$1,
                                  message: items[r * 3 + c].$2,
                                  action: items[r * 3 + c].$4,
                                  onAction: () {},
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-states.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
