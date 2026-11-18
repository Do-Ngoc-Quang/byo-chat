import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/ui/new_chat_page.dart';
import 'package:byo_chat/ui/settings_page.dart';
import 'package:byo_chat/ui/contact_page.dart';
import 'package:byo_chat/ui/msg_menu.dart';
import 'package:byo_chat/ui/states.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Chụp Cài đặt và Trò chuyện mới 390x844 ra PNG để đối chiếu docs/ui (chỉ chạy khi có SHOT_DIR).
void main() {
  final dir = Platform.environment['SHOT_DIR'];
  Future<void> shot(WidgetTester t, String name, Widget page) async {
    final l = FontLoader('Inter')..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Inter.ttf').readAsBytesSync())));
    await l.load();
    final mi = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(File(Platform.environment['ICON_FONT'] ?? '').readAsBytesSync())));
    await mi.load();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: page),
      ),
    );
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  testWidgets(
    'chụp Cài đặt',
    (t) => shot(t, 'flutter-settings', SettingsView(accountCode: 'a1b2c3d4', onLogout: () {})),
    skip: dir == null,
  );
  testWidgets(
    'chụp Trò chuyện mới',
    (t) => shot(t, 'flutter-newchat', const NewChatView(recent: ['Bảo Trân', 'Hoàng Nam', 'Lan Phương'])),
    skip: dir == null,
  );
  testWidgets('chụp Hồ sơ liên hệ', (t) => shot(t, 'flutter-contact', const ContactView(name: 'Bảo Trân')), skip: dir == null);
  testWidgets(
    'chụp Menu tin nhắn',
    (t) => shot(
      t,
      'flutter-msgmenu',
      Container(
        color: const Color(0x8014171F),
        child: const MsgMenuView(text: 'Xong rồi, mình vừa gửi bản 1.0.2.', mine: true, onCopy: _noop),
      ),
    ),
    skip: dir == null,
  );
  testWidgets(
    'chụp Trạng thái',
    (t) => shot(
      t,
      'flutter-states',
      Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Trạng thái dùng chung', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
                const SizedBox(height: 12),
                const StatusBanner('Đang chờ kết nối'),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          StateCard(icon: Icons.chat_bubble_outline, title: 'Chưa có cuộc trò chuyện', message: 'Bắt đầu bằng cách nhắn tin cho ai đó.', action: 'Soạn tin mới', onAction: _noop),
                          const SizedBox(height: 12),
                          StateCard(icon: Icons.error_outline, title: 'Không tải được', message: 'Đã có lỗi xảy ra. Vui lòng thử lại.', action: 'Thử lại', onAction: _noop),
                          const SizedBox(height: 12),
                          const StateCard(icon: Icons.sync, title: 'Đang cập nhật…', message: 'Đang tải các tin nhắn mới.'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          const StateCard(icon: Icons.search, title: 'Không tìm thấy', message: 'Không có kết quả cho “thiết kế”.'),
                          const SizedBox(height: 12),
                          const StateCard(icon: Icons.wifi, title: 'Đang chờ kết nối', message: 'Tin nhắn sẽ được gửi khi có mạng trở lại.'),
                          const SizedBox(height: 12),
                          StateCard(icon: Icons.lock_outline, title: 'Bạn đã được đăng xuất', message: 'Phiên đăng nhập đã hết hạn.', action: 'Đăng nhập lại', onAction: _noop),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    skip: dir == null,
  );
}

void _noop() {}
