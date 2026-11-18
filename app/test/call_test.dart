import 'dart:typed_data';

import 'package:byo_chat/chat/call_controller.dart';
import 'package:byo_chat/chat/call_keys.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/ui/call_label.dart';
import 'package:flutter/material.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/gen/chat/v1/ws.pb.dart' show IncomingCall;
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List k(int b) => Uint8List.fromList(List.filled(32, b));

/// Kiểm (chỉ số, khóa) của khóa gửi: bản ghi không so sánh sâu danh sách nên so từng phần.
void expectSend((int, Uint8List) got, int id, int b) {
  expect(got.$1, id);
  expect(got.$2, k(b));
}

/// Lõi giả: epoch và khóa SFrame theo epoch (khóa = epoch lặp 32 byte), `removed` mô phỏng bị gỡ khỏi nhóm.
class _Core implements ChatCore {
  int epoch = 5;
  bool removed = false;

  @override
  Future<Uint8List> callRaw(String op, Uint8List args) async {
    switch (op) {
      case 'epoch':
        final b = ByteData(8)..setUint32(0, epoch, Endian.little);
        return packList([b.buffer.asUint8List()]);
      case 'sframe_key':
        if (removed) throw ChatCoreException('đã bị gỡ');
        return packList([k(epoch)]);
    }
    throw UnimplementedError(op);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Api implements ChatApi {
  int ticketEpoch = 5;
  final calls = <String>[];
  bool failStart = false;

  CallTicket _t() => CallTicket(callId: Uint8List(16)..[15] = 9, livekitUrl: 'wss://lk', token: 't', mlsEpoch: Int64(ticketEpoch));

  @override
  Future<CallTicket> startCall(StartCallRequest r) async {
    calls.add('start');
    if (failStart) throw ConnectException('already_exists', 'đang có cuộc gọi');
    return _t();
  }

  @override
  Future<CallTicket> joinCall(JoinCallRequest r) async {
    calls.add('join');
    return _t();
  }

  @override
  Future<EndCallResponse> endCall(EndCallRequest r) async {
    calls.add('end');
    return EndCallResponse();
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  group('SframeKeyRing', () {
    test('vào cuộc gọi: gửi và nhận ngay', () {
      final r = SframeKeyRing(5, k(1));
      expectSend(r.sendKey(0), 5, 1);
      expect(r.recvKey(5, 0), k(1));
      expect(r.recvKey(4, 0), isNull);
    });

    test('nhận khóa mới ngay, gửi sau 1 giây, giữ khóa cũ 10 giây', () {
      final r = SframeKeyRing(5, k(1));
      expect(r.onEpoch(6, k(2), 1000), isTrue);
      expect(r.recvKey(6, 1000), k(2));
      expect(r.recvKey(5, 1000), k(1));
      expect(r.sendKey(1999).$1, 5);
      expectSend(r.sendKey(2000), 6, 2);
      expect(r.recvKey(5, 10999), k(1));
      expect(r.recvKey(5, 11000), isNull);
      expect(r.recvKey(6, 11000), k(2));
      expect(r.length, 1);
    });

    test('đổi khóa liên tiếp không mất tiếng; bỏ qua epoch cũ hoặc lặp', () {
      final r = SframeKeyRing(1, k(1));
      r.onEpoch(2, k(2), 100);
      r.onEpoch(3, k(3), 600);
      expect(r.sendKey(700).$1, 1);
      for (final id in [1, 2, 3]) {
        expect(r.recvKey(id, 700), isNotNull, reason: 'khóa $id');
      }
      expect(r.sendKey(1600).$1, 3);
      expect(r.recvKey(1, 10100), isNull);
      expect(r.recvKey(2, 10599), isNotNull);
      expect(r.recvKey(2, 10600), isNull);
      expect(r.onEpoch(3, k(9), 0), isFalse);
      expect(r.onEpoch(2, k(9), 0), isFalse);
    });
  });

  group('CallController', () {
    late _Core core;
    late _Api api;
    late CallController c;
    late int now;
    final conv = Uint8List.fromList([1, 2, 3, 4]);
    var synced = 0;

    setUp(() {
      core = _Core();
      api = _Api();
      now = 1000;
      synced = 0;
      c = CallController(
        api: api,
        core: core,
        nowMs: () => now,
        syncConv: (_) async {
          synced++;
          core.epoch = api.ticketEpoch; // đồng bộ xong thì epoch cục bộ bằng head
        },
      );
    });

    test('gọi đi: có phiếu, khóa SFrame theo epoch, kết nối rồi kết thúc kèm thời lượng', () async {
      await c.start(conv, CallKind.CALL_KIND_VIDEO);
      expect(c.phase, CallPhase.connecting);
      expect(c.ticket!.livekitUrl, 'wss://lk');
      expectSend(c.keys!.sendKey(now), 5, 5);
      c.markConnected();
      expect(c.phase, CallPhase.connected);
      now += 65000;
      expect(await c.end(), 65000);
      expect(c.phase, CallPhase.ended);
      expect(api.calls, ['start', 'end']);
      expect(c.busy, isFalse);
      c.dismiss();
      expect(c.phase, CallPhase.idle);
    });

    test('cuộc gọi đến: đổ chuông, trả lời bằng JoinCall; đang bận thì bỏ qua cuộc thứ hai', () async {
      final inc = IncomingCall(callId: Uint8List(16)..[15] = 9, convId: conv, kind: CallKind.CALL_KIND_AUDIO);
      c.onIncoming(inc);
      expect(c.phase, CallPhase.ringing);
      expect(c.isIncoming, isTrue);
      c.onIncoming(IncomingCall(callId: Uint8List(16)..[15] = 7, convId: conv)); // bận: bỏ qua
      expect(c.callId![15], 9);
      await c.answer();
      expect(c.phase, CallPhase.connecting);
      expect(api.calls, ['join']);
      c.onIncoming(IncomingCall(callId: Uint8List(16)..[15] = 7, convId: conv));
      expect(c.callId![15], 9, reason: 'đang gọi thì không bị đè');
    });

    test('từ chối và người gọi dừng: không gọi server', () {
      c.onIncoming(IncomingCall(callId: Uint8List(16), convId: conv));
      c.decline();
      expect(c.phase, CallPhase.ended);
      c.dismiss();
      c.onIncoming(IncomingCall(callId: Uint8List(16), convId: conv));
      c.onRemoteStopped();
      expect(c.phase, CallPhase.ended);
      expect(api.calls, isEmpty);
    });

    test('epoch lệch phiếu: đồng bộ rồi vào; vẫn lệch thì lỗi và kết thúc cuộc gọi đã tạo', () async {
      core.epoch = 4;
      await c.start(conv, CallKind.CALL_KIND_AUDIO);
      expect(synced, 1);
      expect(c.keys!.sendKey(now).$1, 5);
      await c.end();
      c.dismiss();

      core.epoch = 4;
      api.ticketEpoch = 9; // sau đồng bộ lõi giả đặt epoch = 9 nên ép lệch bằng cách không đồng bộ được
      final stuck = CallController(api: api, core: core, nowMs: () => now, syncConv: (_) async {});
      await expectLater(stuck.start(conv, CallKind.CALL_KIND_AUDIO), throwsA(isA<CallException>()));
      expect(stuck.phase, CallPhase.ended);
      expect(stuck.error, contains('lệch'));
      await Future<void>.delayed(Duration.zero);
      expect(api.calls.where((x) => x == 'end').length, 2, reason: 'cuộc gọi đã tạo ở server được kết thúc');
    });

    test('StartCall lỗi: ném ConnectException, trạng thái kết thúc, có thông báo', () async {
      api.failStart = true;
      await expectLater(c.start(conv, CallKind.CALL_KIND_VIDEO), throwsA(isA<ConnectException>()));
      expect(c.phase, CallPhase.ended);
      expect(c.error, contains('đang có cuộc gọi'));
    });

    test('epoch đổi giữa cuộc gọi: khóa mới nhận ngay, gửi sau 1 giây; hội thoại khác không ảnh hưởng', () async {
      await c.start(conv, CallKind.CALL_KIND_VIDEO);
      core.epoch = 6;
      await c.onEpochChanged(Uint8List.fromList([9, 9]));
      expect(c.keys!.recvKey(6, now), isNull);
      await c.onEpochChanged(conv);
      expect(c.keys!.recvKey(6, now), k(6));
      expect(c.keys!.sendKey(now).$1, 5);
      now += 1000;
      expectSend(c.keys!.sendKey(now), 6, 6);
    });

    test('bị gỡ khỏi nhóm giữa cuộc gọi: không còn khóa mới, cuộc gọi kết thúc ở máy này', () async {
      await c.start(conv, CallKind.CALL_KIND_VIDEO);
      core.epoch = 6;
      core.removed = true;
      await c.onEpochChanged(conv);
      expect(c.phase, CallPhase.ended);
    });
  });

  group('dòng cuộc gọi', () {
    test('chữ theo loại sự kiện và thời lượng', () {
      expect(callLabel(const CallInfo(callId: 'a', kind: CallInfo.started), mine: true), 'Bạn đã gọi');
      expect(callLabel(const CallInfo(callId: 'a', kind: CallInfo.started), mine: false), 'Cuộc gọi đến');
      expect(callLabel(const CallInfo(callId: 'a', kind: CallInfo.ended, durationMs: 754000), mine: true), 'Cuộc gọi · 12:34');
      expect(callLabel(const CallInfo(callId: 'a', kind: CallInfo.ended), mine: true), 'Cuộc gọi đã kết thúc');
      expect(callLabel(const CallInfo(callId: 'a', kind: CallInfo.missed), mine: false), 'Cuộc gọi nhỡ');
    });

    testWidgets('cuộc gọi nhỡ hiện màu đỏ', (t) async {
      await t.pumpWidget(const MaterialApp(home: CallLine(CallInfo(callId: 'a', kind: CallInfo.missed), mine: false)));
      final text = t.widget<Text>(find.text('Cuộc gọi nhỡ'));
      expect(text.style!.color, const Color(0xFFB91C1C));
    });

    test('CallInfo và ChatMessage đi vòng qua JSON', () {
      final m = ChatMessage(id: 'x', mine: true, text: '', tsMs: 1, call: const CallInfo(callId: 'ab', kind: CallInfo.ended, durationMs: 5000));
      final r = ChatMessage.fromJson(m.toJson());
      expect((r.call!.callId, r.call!.kind, r.call!.durationMs), ('ab', 2, 5000));
    });
  });
}
