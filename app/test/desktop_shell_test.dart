import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/auth/session.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/gateway_client.dart';
import 'package:byo_chat/storage/session_store.dart';
import 'package:byo_chat/ui/desktop_shell.dart';
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

/// Engine giả: chỉ trả danh sách hội thoại cố định, không chạm mạng hay lõi MLS.
class _Engine extends ChatEngine {
  _Engine()
    : super(
        session: Session(Uint8List(4), Uint8List(4), _Core(), TokenPair(), 0),
        api: _Api(),
        store: _Store(),
        apiBase: Uri.parse('http://localhost'),
      );

  final _convs = [
    ConvState(convId: Uint8List.fromList([1, 2, 3, 4]), title: 'Minh Anh', lastActivityMs: 2),
    ConvState(convId: Uint8List.fromList([5, 6, 7, 8]), title: 'Bảo Trân', lastActivityMs: 1),
    ConvState(convId: Uint8List.fromList([9, 9, 9, 9]), title: 'Nhóm Dự án', lastActivityMs: 0, isGroup: true),
  ];

  @override
  List<ConvState> get conversations => _convs;

  @override
  List<ChatMessage> messages(String convHex) => convHex == _convs[0].hexId
      ? [
          ChatMessage(id: 'a', mine: false, text: 'Chào bạn, tài liệu thiết kế xong chưa nhỉ?', tsMs: 1, state: MsgState.sent),
          ChatMessage(id: 'b', mine: true, text: 'Xong rồi, mình vừa gửi bản 1.0.2.', tsMs: 2, state: MsgState.sent),
          ChatMessage(id: 'c', mine: false, text: 'Tuyệt, mai mình gặp lúc 9 giờ nhé', tsMs: 3, state: MsgState.sent),
          ChatMessage(id: 'd', mine: true, text: 'Ok, hẹn bạn ở quán quen.', tsMs: 4, state: MsgState.sent),
        ]
      : const [];

  @override
  Future<Set<String>> memberAccounts(String convHex) async => {'aabbccdd11223344', 'eeff001122334455'};

  @override
  GatewayState get connection => GatewayState.online;
}

void main() {
  testWidgets('DesktopShell: chưa chọn thì hiện gợi ý; chọn hàng thì mở khung chat ở cột phải', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    await t.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: DesktopShell(engine: e),
      ),
    );
    expect(find.byKey(const Key('desktop-empty')), findsOneWidget);
    expect(find.byKey(const Key('chat-page')), findsNothing);
    await t.tap(find.byKey(Key('conv-${e.conversations[1].hexId}')));
    await t.pump();
    expect(find.byKey(const Key('chat-page')), findsOneWidget);
    expect(find.byKey(const Key('desktop-empty')), findsNothing);
    expect(find.text('Bảo Trân'), findsWidgets);
  });

  testWidgets('bấm ⓘ ở chat 1-1 mở/đóng bảng hồ sơ 340 bên phải', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    await t.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: DesktopShell(engine: e),
      ),
    );
    await t.tap(find.byKey(Key('conv-${e.conversations[0].hexId}')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('contact-panel')), findsNothing);
    await t.tap(find.byTooltip('Hồ sơ liên hệ'));
    await t.pumpAndSettle();
    expect(t.getSize(find.byKey(const Key('contact-panel'))).width, 340);
    await t.tap(find.byTooltip('Hồ sơ liên hệ'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('contact-panel')), findsNothing);
  });

  testWidgets('bấm ⓘ ở nhóm mở bảng thông tin nhóm 340 bên phải', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: DesktopShell(engine: e)));
    await t.tap(find.byKey(Key('conv-${e.conversations[2].hexId}')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Thông tin nhóm'));
    await t.pumpAndSettle();
    expect(t.getSize(find.byKey(const Key('group-panel'))).width, 340);
    expect(find.text('Gọi video'), findsOneWidget);
    await t.tap(find.byTooltip('Thông tin nhóm'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('group-panel')), findsNothing);
  });

  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp Desktop Inbox', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: Ui.theme(),
          debugShowCheckedModeBanner: false,
          home: DesktopShell(engine: e),
        ),
      ),
    );
    await t.tap(find.byKey(Key('conv-${e.conversations[0].hexId}')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Hồ sơ liên hệ'));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-contact.png')
          .writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);

  testWidgets('chụp Desktop Group', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: DesktopShell(engine: e))));
    await t.tap(find.byKey(Key('conv-${e.conversations[2].hexId}')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Thông tin nhóm'));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-group.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
