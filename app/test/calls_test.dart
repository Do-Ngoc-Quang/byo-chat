import 'dart:io';
import 'dart:ui' as ui;

import 'package:byo_chat/auth/session.dart';
import 'package:byo_chat/chat/call_history.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/gateway_client.dart';
import 'package:byo_chat/storage/session_store.dart';
import 'package:byo_chat/ui/calls_page.dart';
import 'package:byo_chat/ui/desktop_shell.dart';
import 'package:byo_chat/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _ev(String call, int kind, {bool mine = true, int ts = 1000, int dur = 0}) =>
    ChatMessage(id: 'm$call$kind$mine', mine: mine, text: '', tsMs: ts, call: CallInfo(callId: call, kind: kind, durationMs: dur));

void main() {
  group('buildCallHistory', () {
    test('mỗi cuộc gọi một dòng dù có nhiều CallEvent; thời lượng lớn nhất; gọi đi theo bên bắt đầu', () {
      final h = buildCallHistory({
        'c1': [
          _ev('a', CallInfo.started, ts: 100),
          _ev('a', CallInfo.ended, ts: 700, dur: 600000),
          _ev('a', CallInfo.ended, mine: false, ts: 705, dur: 598000),
        ],
      });
      expect(h.length, 1);
      expect((h[0].outgoing, h[0].missed, h[0].durationMs, h[0].tsMs), (true, false, 600000, 100));
    });

    test('nhỡ: có mục nhỡ và không có mục kết thúc; gọi đến khi bên bắt đầu không phải ta', () {
      final h = buildCallHistory({
        'c1': [_ev('x', CallInfo.started, mine: false, ts: 50), _ev('x', CallInfo.missed, mine: false, ts: 60)],
        'c2': [_ev('y', CallInfo.started, mine: false, ts: 200), _ev('y', CallInfo.ended, ts: 900, dur: 5000)],
      });
      expect(h.map((e) => e.callId), ['y', 'x'], reason: 'mới nhất trước');
      expect((h[1].missed, h[1].outgoing), (true, false));
      expect((h[0].missed, h[0].outgoing, h[0].durationMs), (false, false, 5000));
    });

    test('bỏ qua tin không phải cuộc gọi', () {
      expect(buildCallHistory({'c': [ChatMessage(id: 't', mine: true, text: 'xin chào', tsMs: 1)]}), isEmpty);
    });
  });

  test('callWhen: hôm nay, hôm qua, thứ; thời lượng làm tròn lên theo phút; nhỡ không có thời lượng', () {
    final now = DateTime(2026, 11, 18, 12, 0);
    int ms(DateTime d) => d.millisecondsSinceEpoch;
    CallEntry e(DateTime t, {int dur = 0, bool missed = false}) =>
        CallEntry(callId: 'a', convHex: 'c', tsMs: ms(t), missed: missed, outgoing: true, durationMs: dur);
    expect(callWhen(e(DateTime(2026, 11, 18, 9, 2), dur: 61000), now: now), 'Hôm nay, 09:02 · 2 phút');
    expect(callWhen(e(DateTime(2026, 11, 17, 20, 15), dur: 12 * 60000), now: now), 'Hôm qua, 20:15 · 12 phút');
    expect(callWhen(e(DateTime(2026, 11, 16, 18, 40)), now: now), 'Thứ hai, 18:40');
    expect(callWhen(e(DateTime(2026, 11, 17, 9, 2), dur: 5000, missed: true), now: now), 'Hôm qua, 09:02');
  });

  testWidgets('CallsView: lọc Nhỡ, trạng thái trống, mở hàng và gọi lại', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final opened = <String>[], called = <String>[];
    final entries = [
      const CallEntry(callId: 'a', convHex: 'c1', tsMs: 3000, missed: false, outgoing: true, durationMs: 720000),
      const CallEntry(callId: 'b', convHex: 'c2', tsMs: 2000, missed: true, outgoing: false, durationMs: 0),
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: CallsView(entries: entries, nameOf: (h) => h == 'c1' ? 'Hoàng Nam' : 'Minh Anh', onOpen: (e) => opened.add(e.callId), onCallBack: (e) => called.add(e.callId)),
      ),
    );
    expect(find.byKey(const Key('call-row-a')), findsOneWidget);
    expect(find.byKey(const Key('call-row-b')), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('call-row-a'))).height, 68);
    await t.tap(find.byKey(const Key('call-row-a')));
    await t.tap(find.byKey(const Key('call-back-b')));
    expect(opened, ['a']);
    expect(called, ['b']);
    await t.tap(find.byKey(const Key('calls-filter-missed')));
    await t.pump();
    expect(find.byKey(const Key('call-row-a')), findsNothing);
    expect(find.byKey(const Key('call-row-b')), findsOneWidget);
    expect(t.widget<Text>(find.text('Minh Anh')).style!.color, const Color(0xFFDC2626));
  });

  testWidgets('CallsView trống: thông báo theo bộ lọc', (t) async {
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: CallsView(entries: const [], nameOf: (_) => '')));
    expect(find.text('Chưa có cuộc gọi nào'), findsOneWidget);
    await t.tap(find.byKey(const Key('calls-filter-missed')));
    await t.pump();
    expect(find.text('Không có cuộc gọi nhỡ'), findsOneWidget);
  });

  testWidgets('DesktopShell: biểu tượng gọi ở thanh trái mở lịch sử cột 480; chạm hàng quay về khung chat', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final e = _Engine();
    await t.pumpWidget(MaterialApp(theme: Ui.theme(), home: DesktopShell(engine: e)));
    await t.tap(find.byKey(const Key('rail-calls')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('calls-title')), findsOneWidget);
    expect(find.byKey(const Key('calls-detail-empty')), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('calls-title'))).height, greaterThan(0));
    await t.tap(find.byKey(const Key('call-row-a')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('calls-title')), findsNothing);
    expect(find.byKey(const Key('chat-page')), findsOneWidget);
  });

  final dir = Platform.environment['SHOT_DIR'];
  testWidgets('chụp lịch sử cuộc gọi', (t) async {
    for (final f in [('Inter', 'assets/fonts/Inter.ttf'), ('MaterialIcons', Platform.environment['ICON_FONT'] ?? '')]) {
      final l = FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(File(f.$2).readAsBytesSync())));
      await l.load();
    }
    final now = DateTime.now();
    int ago(int days, int h, int m) => DateTime(now.year, now.month, now.day - days, h, m).millisecondsSinceEpoch;
    final entries = [
      CallEntry(callId: '1', convHex: 'a', tsMs: ago(1, 20, 15), missed: false, outgoing: true, durationMs: 12 * 60000),
      CallEntry(callId: '2', convHex: 'b', tsMs: ago(1, 9, 2), missed: true, outgoing: false, durationMs: 0),
      CallEntry(callId: '3', convHex: 'c', tsMs: ago(3, 18, 40), missed: false, outgoing: false, durationMs: 4 * 60000),
      CallEntry(callId: '4', convHex: 'd', tsMs: ago(3, 12, 10), missed: false, outgoing: true, durationMs: 31 * 60000),
    ];
    const names = {'a': 'Hoàng Nam', 'b': 'Minh Anh', 'c': 'Bảo Trân', 'd': 'Gia đình'};
    for (final (w, h, tag, desk) in [(390.0, 844.0, 'mobile', false), (480.0, 800.0, 'desktop', true)]) {
      t.view.physicalSize = Size(w, h);
      t.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(theme: Ui.theme(), debugShowCheckedModeBanner: false, home: CallsView(entries: entries, nameOf: (x) => names[x]!, desktop: desk))));
      await t.pump();
      await t.runAsync(() async {
        final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 1);
        File('$dir/flutter-$tag-calls.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      });
    }
    addTearDown(t.view.reset);
  }, skip: dir == null);
}

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

class _Engine extends ChatEngine {
  _Engine() : super(session: Session(Uint8List(4), Uint8List(4), _Core(), TokenPair(), 0), api: _Api(), store: _Store(), apiBase: Uri.parse('http://localhost'));
  final _conv = ConvState(convId: Uint8List.fromList([1, 2, 3, 4]), title: 'Hoàng Nam');

  @override
  List<ConvState> get conversations => [_conv];
  @override
  List<ChatMessage> messages(String convHex) => const [];
  @override
  List<CallEntry> callHistory() => [CallEntry(callId: 'a', convHex: _conv.hexId, tsMs: DateTime.now().millisecondsSinceEpoch, missed: false, outgoing: true, durationMs: 60000)];
  @override
  GatewayState get connection => GatewayState.online;
}
