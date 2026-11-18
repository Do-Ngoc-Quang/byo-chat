import 'dart:async';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/core/chatcore_api.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/ui/device_pages.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lõi giả: chỉ đủ cho bước 1 của liên kết (mở thiết bị chờ, sinh khóa). `openPending`/`linkStart` là extension
/// nên giả ở mức `openDeviceRaw`/`callRaw`.
class _Core implements ChatCore {
  @override
  Future<void> openDeviceRaw(Uint8List packedArgs) async {}

  @override
  Future<Uint8List> callRaw(String op, Uint8List packedArgs) async {
    if (op == 'link_start') return packList([Uint8List(32), Uint8List(32)]);
    throw UnimplementedError(op);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

/// Máy chủ giả: StartLink trả mã 481729; CompleteLink treo mãi (chưa ai duyệt).
class _Api implements ChatApi {
  @override
  Future<StartLinkResponse> startLink(StartLinkRequest r) async => StartLinkResponse(linkId: List.filled(16, 7), shortCode: '481729');

  @override
  Future<CompleteLinkResponse> completeLink(CompleteLinkRequest r) => Completer<CompleteLinkResponse>().future;

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

// Liên kết thiết bị mới trên Desktop (Desktop-Link): thẻ 880 hai cột; điện thoại giữ bố cục một cột.
void main() {
  Future<GlobalKey> pump(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    final c = LoginController(api: _Api(), openCore: () async => _Core());
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: Ui.theme(),
          debugShowCheckedModeBanner: false,
          home: LinkNewDevicePage(login: c),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    return key;
  }

  testWidgets('rộng ≥ 900: có QR và mã xác nhận 481 729 ở cột phải, kèm nút Tạo mã mới', (t) async {
    await pump(t, const Size(1280, 800));
    expect(t.getSize(find.byKey(const Key('link-qr'))).width, 220);
    expect(find.text('481 729'), findsOneWidget);
    expect(find.text('Đăng nhập trên máy tính'), findsOneWidget);
    expect(find.text('Tạo mã mới'), findsOneWidget);
    expect(find.text('Đang chờ phê duyệt…'), findsOneWidget);
  });

  testWidgets('điện thoại: bố cục cũ, không có thẻ hai cột', (t) async {
    await pump(t, const Size(390, 844));
    expect(find.text('Đăng nhập trên máy tính'), findsNothing);
    expect(find.byKey(const Key('new-short-code')), findsOneWidget);
  });

  final dir = io.Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop Link', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', io.Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(io.File(f.$2).readAsBytesSync())));
      await l.load();
    }
    final key = await pump(t, const Size(1280, 800));
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      io.File('$dir/flutter-desktop-link.png')
          .writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
