import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/ui/settings_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Cài đặt Desktop (Desktop-Settings): danh sách mục 300 + nội dung; Sao lưu/Thiết bị mở trang riêng.
void main() {
  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: w));
    await t.pumpAndSettle();
  }

  testWidgets('đổi mục và gọi các callback', (t) async {
    var backup = 0, devices = 0, logout = 0;
    await pump(
      t,
      SettingsDesktopView(accountCode: 'a1b2c3d4', onBackup: () => backup++, onDevices: () => devices++, onLogout: () => logout++),
    );
    expect(find.text('Mã a1b2c3d4…'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('settings-desktop'))).width, 1280);
    await t.tap(find.byKey(const Key('settings-logout')));
    expect(logout, 1);
    await t.tap(find.byKey(const Key('sec-notifications')));
    await t.pumpAndSettle();
    expect(find.text('Bật thông báo'), findsOneWidget);
    expect(find.byKey(const Key('settings-logout')), findsNothing);
    await t.tap(find.byKey(const Key('sec-backup')));
    await t.tap(find.byKey(const Key('sec-devices')));
    await t.tap(find.byKey(const Key('sec-privacy')));
    expect([backup, devices], [1, 1]);
  });

  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop Settings', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: Ui.theme(),
          debugShowCheckedModeBanner: false,
          home: const SettingsDesktopView(accountCode: 'a1b2c3d4'),
        ),
      ),
    );
    await t.tap(find.byKey(const Key('sec-notifications')));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-settings.png')
          .writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
