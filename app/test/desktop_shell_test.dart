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
  ];

  @override
  List<ConvState> get conversations => _convs;

  @override
  List<ChatMessage> messages(String convHex) => const [];

  @override
  GatewayState get connection => GatewayState.online;
}

void main() {
  testWidgets('DesktopShell: chưa chọn thì hiện gợi ý; chọn hàng thì mở khung chat ở cột phải', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: DesktopShell(engine: e)));
    expect(find.byKey(const Key('desktop-empty')), findsOneWidget);
    expect(find.byKey(const Key('chat-page')), findsNothing);
    await t.tap(find.byKey(Key('conv-${e.conversations[1].hexId}')));
    await t.pump();
    expect(find.byKey(const Key('chat-page')), findsOneWidget);
    expect(find.byKey(const Key('desktop-empty')), findsNothing);
    expect(find.text('Bảo Trân'), findsWidgets);
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
    await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: DesktopShell(engine: e))));
    await t.tap(find.byKey(Key('conv-${e.conversations[0].hexId}')));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-desktop-inbox.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
