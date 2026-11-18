import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/ui/profile_setup_page.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ProfileSetupView: Hoàn tất tắt khi chưa có tên; có tên thì gọi onDone với tên đã cắt khoảng trắng', (t) async {
    String? done;
    await t.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: ProfileSetupView(onDone: (v) => done = v),
      ),
    );
    expect(t.widget<FilledButton>(find.byKey(const Key('profile-done'))).onPressed, isNull);
    await t.enterText(find.byKey(const Key('profile-name')), '  Nguyễn Bảo ');
    await t.pump();
    expect(find.text('B'), findsOneWidget);
    await t.tap(find.byKey(const Key('profile-done')));
    expect(done, 'Nguyễn Bảo');
  });

  Future<GlobalKey> pumpSized(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: Ui.theme(),
          debugShowCheckedModeBanner: false,
          home: const ProfileSetupView(initialName: 'Nguyễn Bảo', onDone: _noop),
        ),
      ),
    );
    await t.pumpAndSettle();
    return key;
  }

  testWidgets('rộng ≥ 900: thẻ 440 ở giữa; điện thoại không có thẻ', (t) async {
    await pumpSized(t, const Size(1280, 800));
    expect(t.getSize(find.byKey(const Key('profile-card'))).width, 440);
    expect(t.getCenter(find.byKey(const Key('profile-card'))).dx, 640);
    await pumpSized(t, const Size(390, 800));
    expect(find.byKey(const Key('profile-card')), findsNothing);
  });

  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop Profile', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    final key = await pumpSized(t, const Size(1280, 800));
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-profile.png')
          .writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}

void _noop(String _) {}
