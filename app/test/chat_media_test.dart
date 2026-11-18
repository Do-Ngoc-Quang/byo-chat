import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:byo_chat/auth/session.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/chat/media.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/gateway_client.dart';
import 'package:byo_chat/storage/session_store.dart';
import 'package:byo_chat/ui/chat_page.dart';
import 'package:byo_chat/ui/media_picker.dart';
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

final _png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

MediaRef _ref(String mime, {String name = ''}) => MediaRef(
  mediaId: Uint8List(16),
  key: Uint8List(32),
  noncePrefix: Uint8List(7),
  sha256: Uint8List(32),
  size: 2048,
  mime: mime,
  name: name,
  width: 400,
  height: 300,
);

class _Engine extends ChatEngine {
  _Engine()
    : super(
        session: Session(Uint8List(4), Uint8List(4), _Core(), TokenPair(), 0),
        api: _Api(),
        store: _Store(),
        apiBase: Uri.parse('http://localhost'),
      );

  final conv = ConvState(convId: Uint8List.fromList([1, 2, 3, 4]), title: 'Minh Anh');
  bool failLoad = false;
  final sent = <(String, Uint8List, String, String, int, int)>[];

  @override
  List<ConvState> get conversations => [conv];

  @override
  List<ChatMessage> messages(String convHex) => [
    ChatMessage(id: 'img', mine: false, text: 'ảnh dự án', tsMs: 1, state: MsgState.received, media: _ref('image/png', name: 'a.png')),
    ChatMessage(id: 'doc', mine: true, text: '', tsMs: 2, state: MsgState.sent, media: _ref('application/pdf', name: 'bao-cao.pdf')),
  ];

  @override
  Future<Uint8List> mediaBytes(ChatMessage m) async {
    if (failLoad) throw ChatException('hỏng');
    return _png;
  }

  @override
  Future<void> sendMedia(String convHex, Uint8List bytes, {required String mime, String name = '', String caption = '', int width = 0, int height = 0}) async {
    sent.add((convHex, bytes, mime, name, width, height));
  }

  @override
  GatewayState get connection => GatewayState.online;
}

class _Picker implements MediaPicker {
  @override
  Future<PickedMedia?> pickImage() async => PickedMedia(bytes: _png, mime: 'image/png', name: 'x.png', width: 1, height: 1);
  @override
  Future<PickedMedia?> pickFile() async => PickedMedia(bytes: Uint8List.fromList([1, 2]), mime: 'application/pdf', name: 'f.pdf');
}

Future<_Engine> _pump(WidgetTester t, {bool failLoad = false}) async {
  final e = _Engine()..failLoad = failLoad;
  await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: ChatPage(engine: e, conv: e.conv, picker: _Picker())));
  await t.pump();
  return e;
}

void main() {
  testWidgets('ảnh nhận được hiện trong bong bóng kèm chú thích; chạm mở trình xem', (t) async {
    await _pump(t);
    expect(find.byKey(const Key('image-img')), findsOneWidget);
    expect(find.text('ảnh dự án'), findsOneWidget);
    await t.tap(find.byKey(const Key('image-img')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('viewer-page')), findsOneWidget);
    await t.tap(find.byKey(const Key('viewer-close')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-page')), findsOneWidget);
  });

  testWidgets('tệp không phải ảnh hiện tên và dung lượng', (t) async {
    await _pump(t);
    expect(find.byKey(const Key('file-doc')), findsOneWidget);
    expect(find.text('bao-cao.pdf'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
  });

  testWidgets('tải ảnh lỗi: hiện thông báo và nút thử lại', (t) async {
    final e = await _pump(t, failLoad: true);
    expect(find.byKey(const Key('image-error-img')), findsOneWidget);
    e.failLoad = false;
    await t.tap(find.byKey(const Key('image-error-img')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('image-img')), findsOneWidget);
  });

  testWidgets('nút + (mobile) mở menu; chọn Ảnh và Tệp gọi sendMedia với đúng dữ liệu', (t) async {
    final e = await _pump(t);
    await t.tap(find.byKey(const Key('attach-button')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-image')));
    await t.pumpAndSettle();
    expect(e.sent.single.$3, 'image/png');
    expect((e.sent.single.$4, e.sent.single.$5, e.sent.single.$6), ('x.png', 1, 1));
    expect(e.sent.single.$1, e.conv.hexId);

    await t.tap(find.byKey(const Key('attach-button')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file')));
    await t.pumpAndSettle();
    expect(e.sent.length, 2);
    expect(e.sent.last.$4, 'f.pdf');
  });

  // Chụp màn hình để đối chiếu thủ công: SHOT_DIR=/tmp/shots ICON_FONT=<MaterialIcons-Regular.otf> flutter test
  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp chat có ảnh và tệp (Mobile)', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: ChatPage(engine: e, conv: e.conv, picker: _Picker()))));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // chờ giải mã ảnh
    await t.pump();
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      File('$dir/flutter-mobile-chat-media.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  }, skip: dir == null);
}
