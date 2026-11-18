import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:byo_chat/auth/session.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/storage/session_store.dart';
import 'package:byo_chat/ui/device_pages.dart';
import 'package:byo_chat/ui/settings_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Core implements ChatCore {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Api implements ChatApi {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Store implements SessionStore {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

/// Engine giả: chỉ trả danh sách thiết bị cố định.
class _Engine extends ChatEngine {
  _Engine()
    : super(
        session: Session(Uint8List.fromList([1, 2, 3, 4]), Uint8List.fromList([9, 9, 9, 9]), _Core(), TokenPair(), 0),
        api: _Api(),
        store: _Store(),
        apiBase: Uri.parse('http://localhost'),
      );

  @override
  Future<List<DeviceInfo>> listDevices() async => [
    DeviceInfo(deviceId: [9, 9, 9, 9], deviceName: 'iPhone 15', platform: Platform.PLATFORM_IOS),
    DeviceInfo(deviceId: [8, 8, 8, 8], deviceName: 'Chrome trên Windows', platform: Platform.PLATFORM_WEB),
  ];
}

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

  testWidgets('mục Thiết bị nhúng: hiện danh sách và nút Liên kết ngay bên phải, không mở trang mới', (t) async {
    await pump(
      t,
      SettingsDesktopView(
        accountCode: 'a1b2c3d4',
        devices: DevicesPage(engine: _Engine(), embedded: true),
      ),
    );
    expect(find.byKey(const Key('devices-panel')), findsNothing);
    await t.tap(find.byKey(const Key('sec-devices')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('devices-panel')), findsOneWidget);
    expect(find.text('Chrome trên Windows'), findsOneWidget);
    expect(find.text('Thiết bị này'), findsOneWidget);
    expect(find.byKey(const Key('add-device')), findsOneWidget);
    expect(find.byKey(const Key('revoke-08080808')), findsOneWidget);
    expect(find.byKey(const Key('settings-desktop')), findsOneWidget);
  });

  final dir = io.Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop Settings', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', io.Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(io.File(f.$2).readAsBytesSync())));
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
      io.File('$dir/flutter-desktop-settings.png')
          .writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);

  testWidgets('chụp Desktop Devices', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', io.Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(io.File(f.$2).readAsBytesSync())));
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
          home: SettingsDesktopView(
            accountCode: 'a1b2c3d4',
            devices: DevicesPage(engine: _Engine(), embedded: true),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const Key('sec-devices')));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      io.File('$dir/flutter-desktop-devices.png')
          .writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
