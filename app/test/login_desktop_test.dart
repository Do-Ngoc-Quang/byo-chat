import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/ui/login_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_server.dart';

// Đăng nhập Desktop (Desktop-Login): thẻ giữa rộng 440; điện thoại thì không có thẻ.
void main() {
  Future<LoginController> pump(WidgetTester t, Size size, {Key? key}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = LoginController(api: FakeServer().api, openCore: () async => FakeCore());
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: Ui.theme(),
          debugShowCheckedModeBanner: false,
          home: LoginPage(controller: c),
        ),
      ),
    );
    await t.pumpAndSettle();
    return c;
  }

  testWidgets('rộng ≥ 900: thẻ 440 ở giữa', (t) async {
    await pump(t, const Size(1280, 800));
    final card = find.byKey(const Key('login-card'));
    expect(card, findsOneWidget);
    expect(t.getSize(card).width, 440);
    expect(t.getCenter(card).dx, 640);
    expect(find.byKey(const Key('request-otp')), findsOneWidget);
  });

  testWidgets('điện thoại: không có thẻ', (t) async {
    await pump(t, const Size(390, 844));
    expect(find.byKey(const Key('login-card')), findsNothing);
    expect(find.byKey(const Key('request-otp')), findsOneWidget);
  });

  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop Login', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    final key = GlobalKey();
    await pump(t, const Size(1280, 800), key: key);
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-login.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
