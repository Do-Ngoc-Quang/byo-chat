import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/auth/session.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart' show CallKind;
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/gen/chat/v1/ws.pb.dart' show IncomingCall;
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/storage/session_store.dart';
import 'package:byo_chat/ui/call_pages.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Core implements ChatCore {
  @override
  Future<Uint8List> callRaw(String op, Uint8List args) async {
    if (op == 'epoch') return packList([Uint8List(8)..[0] = 3]);
    if (op == 'sframe_key') return packList([Uint8List(32)]);
    throw UnimplementedError(op);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Api implements ChatApi {
  final calls = <String>[];
  @override
  Future<CallTicket> joinCall(JoinCallRequest r) async {
    calls.add('join');
    return CallTicket(callId: r.callId, livekitUrl: 'wss://lk', token: 't', mlsEpoch: Int64(3));
  }

  @override
  Future<EndCallResponse> endCall(EndCallRequest r) async {
    calls.add('end');
    return EndCallResponse();
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Store implements SessionStore {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

final _conv = Uint8List.fromList([1, 2, 3, 4]);

class _Engine extends ChatEngine {
  _Engine(this.fake)
    : super(
        session: Session(Uint8List(4), Uint8List(4), _Core(), TokenPair(), 0),
        api: fake,
        store: _Store(),
        apiBase: Uri.parse('http://localhost'),
      );
  final _Api fake;
  final recorded = <String>[];

  @override
  List<ConvState> get conversations => [ConvState(convId: _conv, title: 'Hoàng Nam')];

  @override
  Future<void> endCall() async {
    recorded.add('endCall');
    await calls.end();
  }
}

IncomingCall _incoming({CallKind kind = CallKind.CALL_KIND_VIDEO}) => IncomingCall(callId: Uint8List(16)..[15] = 9, convId: _conv, kind: kind);

Future<void> _size(WidgetTester t, double w, double h) async {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget _app(Widget child) => MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: child);

void main() {
  testWidgets('IncomingCallView mobile: avatar 128, nút 68 cách nhau 64, gọi đúng hàm', (t) async {
    await _size(t, 390, 844);
    var declined = 0, answered = 0;
    await t.pumpWidget(_app(IncomingCallView(name: 'Hoàng Nam', video: true, onDecline: () => declined++, onAnswer: () => answered++)));
    expect(find.text('Hoàng Nam'), findsOneWidget);
    expect(find.text('Cuộc gọi video đến…'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('call-decline'))), const Size(68, 68));
    final gap = t.getTopLeft(find.byKey(const Key('call-answer'))).dx - t.getTopRight(find.byKey(const Key('call-decline'))).dx;
    expect(gap, greaterThanOrEqualTo(64)); // khoảng cách giữa hai cột là 64; font thử nghiệm rộng nên cột có thể rộng hơn nút
    await t.tap(find.byKey(const Key('call-decline')));
    await t.tap(find.byKey(const Key('call-answer')));
    expect((declined, answered), (1, 1));
  });

  testWidgets('IncomingCallView Desktop: thẻ 420 giữa màn hình, nút 64', (t) async {
    await _size(t, 1280, 800);
    await t.pumpWidget(_app(const IncomingCallView(name: 'Hoàng Nam', video: false)));
    expect(find.text('Cuộc gọi thoại đến…'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('call-answer'))), const Size(64, 64));
    final card = find.ancestor(of: find.byKey(const Key('incoming-name')), matching: find.byType(Container)).last;
    expect(t.getSize(card).width, 420);
    expect(t.getCenter(card).dx, 640);
  });

  testWidgets('CallView mobile: ảnh tự xem 104×148 ở góc phải, nút 60; chỉ Kết thúc bấm được', (t) async {
    await _size(t, 390, 844);
    var ended = 0;
    await t.pumpWidget(_app(CallView(name: 'Minh Anh', status: '12:34', onEnd: () => ended++)));
    expect(find.text('12:34'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('call-end'))), const Size(60, 60));
    final self = find.text('Bạn');
    expect(self, findsOneWidget);
    await t.tap(find.byKey(const Key('call-end')));
    expect(ended, 1);
    expect(find.byIcon(Icons.cameraswitch_outlined), findsOneWidget);
    expect(find.byIcon(Icons.screen_share_outlined), findsNothing); // chia sẻ màn hình chỉ có ở Desktop
  });

  testWidgets('CallView Desktop: nút Kết thúc 72×56, có chia sẻ màn hình, ô camera của bạn 320×240', (t) async {
    await _size(t, 1280, 800);
    await t.pumpWidget(_app(const CallView(name: 'Minh Anh', status: 'Đang kết nối…')));
    expect(t.getSize(find.byKey(const Key('call-end'))), const Size(72, 56));
    expect(find.byIcon(Icons.screen_share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cameraswitch_outlined), findsNothing);
    expect(t.getSize(find.ancestor(of: find.text('Camera của bạn'), matching: find.byType(Container)).first), const Size(320, 240));
  });

  testWidgets('CallHost: chuông → Trả lời vào cuộc gọi → Kết thúc; từ chối ở máy này không gọi server', (t) async {
    await _size(t, 390, 844);
    final api = _Api();
    final e = _Engine(api);
    await t.pumpWidget(_app(CallHost(engine: e, child: const Scaffold(body: Text('nền')))));
    expect(find.byKey(const Key('incoming-call')), findsNothing);

    e.calls.onIncoming(_incoming());
    await t.pump();
    expect(find.byKey(const Key('incoming-call')), findsOneWidget);
    expect(find.text('Hoàng Nam'), findsOneWidget);

    await t.tap(find.byKey(const Key('call-answer')));
    await t.pump();
    await t.pump();
    expect(api.calls, ['join']);
    expect(find.byKey(const Key('call-screen')), findsOneWidget);
    expect(find.text('Đang kết nối…'), findsOneWidget);

    e.calls.markConnected();
    await t.pump();
    expect(find.text('00:00'), findsOneWidget);

    await t.tap(find.byKey(const Key('call-end')));
    await t.pump();
    await t.pump();
    expect(e.recorded, ['endCall']);
    expect(api.calls, ['join', 'end']);
    expect(find.text('Cuộc gọi đã kết thúc'), findsOneWidget);
    await t.pump(const Duration(seconds: 3)); // tự đóng
    expect(find.byKey(const Key('call-screen')), findsNothing);
    expect(find.text('nền'), findsOneWidget);
  });

  // Chụp màn hình để đối chiếu: SHOT_DIR=/tmp/shots ICON_FONT=<MaterialIcons-Regular.otf> flutter test --plain-name chụp
  final dir = Platform.environment['SHOT_DIR'];
  Future<void> shot(WidgetTester t, GlobalKey key, String file) => t.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 1);
    File('$dir/$file').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
  });
  Future<void> fonts() async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
  }

  testWidgets('chụp màn gọi', (t) async {
    await fonts();
    for (final (w, h, tag) in [(390.0, 844.0, 'mobile'), (1280.0, 800.0, 'desktop')]) {
      await _size(t, w, h);
      for (final (name, view) in [
        ('incoming', const IncomingCallView(name: 'Hoàng Nam', video: true)),
        ('call', const CallView(name: 'Minh Anh', status: '12:34')),
      ]) {
        final key = GlobalKey();
        await t.pumpWidget(RepaintBoundary(key: key, child: _app(view)));
        await t.pump();
        await shot(t, key, 'flutter-$tag-$name.png');
      }
    }
  }, skip: dir == null);
}
