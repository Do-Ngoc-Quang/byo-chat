import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/chatcore.dart';
import '../gen/chat/v1/common.pbenum.dart' show CallKind;
import '../gen/chat/v1/services.pb.dart';
import '../gen/chat/v1/ws.pb.dart' show IncomingCall;
import '../net/api.dart';
import '../net/connect_client.dart';
import 'call_keys.dart';

/// Pha của cuộc gọi trên thiết bị này (spec man-hinh.md S-12, S-13).
enum CallPhase {
  idle,

  /// Có cuộc gọi đến, chưa trả lời (S-13).
  ringing,

  /// Đã có phiếu LiveKit và khóa SFrame, đang kết nối luồng media (phần media cần LiveKit thật).
  connecting,
  connected,
  ended,
}

class CallException implements Exception {
  CallException(this.message);
  final String message;
  @override
  String toString() => 'CallException: $message';
}

/// Điều phối một cuộc gọi: gọi/nhận/trả lời/kết thúc qua CallService, dẫn xuất khóa SFrame từ MLS và đổi khóa khi epoch
/// đổi. Không đụng media: lớp LiveKit nhận [ticket], [keys] rồi gọi [markConnected]. Mỗi thiết bị chỉ một cuộc gọi.
class CallController extends ChangeNotifier {
  CallController({required this.api, required this.core, required this.syncConv, this.nowMs});

  final ChatApi api;
  final ChatCore core;

  /// Đồng bộ log hội thoại tới head khi epoch cục bộ lệch `mls_epoch` của phiếu (6.9 bước 3).
  final Future<void> Function(Uint8List conv) syncConv;
  final int Function()? nowMs;

  int _now() => nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  CallPhase phase = CallPhase.idle;
  IncomingCall? incoming;
  CallTicket? ticket;
  Uint8List? convId, callId;
  CallKind kind = CallKind.CALL_KIND_UNSPECIFIED;
  bool isIncoming = false;
  String? error;
  int? startedAtMs;
  SframeKeyRing? keys;

  bool get busy => phase != CallPhase.idle && phase != CallPhase.ended;

  /// Cuộc gọi đến qua khung IncomingCall. Đang bận thì bỏ qua (không có RPC từ chối; người gọi tự hết chuông).
  void onIncoming(IncomingCall c) {
    if (busy) return;
    _reset();
    incoming = c;
    callId = Uint8List.fromList(c.callId);
    convId = Uint8List.fromList(c.convId);
    kind = c.kind;
    isIncoming = true;
    phase = CallPhase.ringing;
    notifyListeners();
  }

  Future<void> start(Uint8List conv, CallKind k) async {
    if (busy) throw CallException('Đang có cuộc gọi khác');
    _reset();
    convId = conv;
    kind = k;
    isIncoming = false;
    await _enter(() => api.startCall(StartCallRequest(convId: conv, kind: k)));
  }

  /// Trả lời cuộc gọi đến.
  Future<void> answer() async {
    if (phase != CallPhase.ringing) throw CallException('Không có cuộc gọi đến');
    final id = callId!;
    await _enter(() => api.joinCall(JoinCallRequest(callId: id)));
  }

  /// Từ chối: chỉ bỏ chuông ở máy này (spec chưa có RPC từ chối).
  void decline() {
    if (phase != CallPhase.ringing) return;
    phase = CallPhase.ended;
    notifyListeners();
  }

  /// Người gọi dừng trước khi ta trả lời, hoặc thiết bị khác của ta đã trả lời: tự đóng.
  void onRemoteStopped() {
    if (phase == CallPhase.ringing) {
      phase = CallPhase.ended;
      notifyListeners();
    }
  }

  Future<void> _enter(Future<CallTicket> Function() getTicket) async {
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      final t = await getTicket();
      final conv = convId!;
      callId = Uint8List.fromList(t.callId);
      var epoch = await core.epoch(conv);
      if (epoch != t.mlsEpoch.toInt()) {
        await syncConv(conv); // chỉ vào khi epoch khớp phiếu (6.9 bước 3)
        epoch = await core.epoch(conv);
      }
      if (epoch != t.mlsEpoch.toInt()) throw CallException('Epoch cục bộ lệch epoch của cuộc gọi, thử lại sau');
      keys = SframeKeyRing(epoch, await core.sframeKey(conv, callId!));
      ticket = t;
      startedAtMs = _now();
      notifyListeners();
    } on ConnectException catch (e) {
      await _fail('Không vào được cuộc gọi: ${e.message}');
      rethrow;
    } on CallException catch (e) {
      await _fail(e.message);
      // Đã có cuộc gọi ở server (ta là người gọi): kết thúc để hội thoại gọi lại được.
      if (!isIncoming && callId != null) unawaited(api.endCall(EndCallRequest(callId: callId!)).then((_) {}, onError: (_) {}));
      rethrow;
    } on ChatCoreException catch (e) {
      await _fail('Lỗi khóa cuộc gọi: ${e.message}');
      throw CallException(error!);
    }
  }

  Future<void> _fail(String msg) async {
    error = msg;
    phase = CallPhase.ended;
    notifyListeners();
  }

  /// Lớp media báo đã nối được LiveKit.
  void markConnected() {
    if (phase != CallPhase.connecting) return;
    phase = CallPhase.connected;
    notifyListeners();
  }

  /// Epoch của hội thoại đổi giữa cuộc gọi (có người vào/ra): dẫn xuất khóa mới, đặt chỉ số kế tiếp.
  Future<void> onEpochChanged(Uint8List conv) async {
    final k = keys;
    if (k == null || !busy || callId == null || convId == null || !listEquals(conv, convId)) return;
    try {
      k.onEpoch(await core.epoch(conv), await core.sframeKey(conv, callId!), _now());
    } on ChatCoreException {
      // Bị gỡ khỏi nhóm: không còn khóa mới, kết thúc cuộc gọi ở máy này.
      await end();
    }
  }

  /// Kết thúc cuộc gọi; thời lượng (ms) trả về để gửi `CallEvent` vào hội thoại (6.9 bước 5). 0 nếu chưa vào cuộc gọi.
  Future<int> end() async {
    if (!busy) return 0;
    final dur = ticket == null || startedAtMs == null ? 0 : _now() - startedAtMs!;
    final id = callId;
    phase = CallPhase.ended;
    keys = null;
    notifyListeners();
    if (id != null && ticket != null) {
      try {
        await api.endCall(EndCallRequest(callId: id));
      } on ConnectException {
        // Hết hạn tự dọn ở server; không chặn việc kết thúc ở máy này.
      }
    }
    return dur;
  }

  /// Trở về rảnh sau khi UI đã hiện trạng thái kết thúc.
  void dismiss() {
    _reset();
    notifyListeners();
  }

  void _reset() {
    phase = CallPhase.idle;
    incoming = null;
    ticket = null;
    convId = callId = null;
    kind = CallKind.CALL_KIND_UNSPECIFIED;
    isIncoming = false;
    error = null;
    startedAtMs = null;
    keys = null;
  }
}
