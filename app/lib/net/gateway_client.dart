import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/ws.pb.dart';

/// Trạng thái kết nối (giao-thuc.md 7.2).
enum GatewayState { disconnected, connecting, authenticating, syncing, online, backoff, stopped }

/// Lỗi từ gateway hoặc từ phía kết nối.
class GatewayException implements Exception {
  GatewayException(this.message, {this.code, this.currentEpoch = 0, this.retryAfterMs = 0});

  final String message;
  final ErrorCode? code;
  final int currentEpoch;
  final int retryAfterMs;

  @override
  String toString() => 'GatewayException($code: $message)';
}

/// Client WebSocket `chat.v1` (giao-thuc.md mục 3): Hello, Welcome, tồn đọng, SyncDone, Ack sau khi đã
/// ghi bền, heartbeat, kết nối lại với backoff, xử lý mã đóng 4002/4003/4004/4010.
class GatewayClient {
  GatewayClient({
    required this.url,
    required this.deviceId,
    required this.platform,
    required this.accessToken,
    required this.inboxCursor,
    required this.onDeliver,
    this.onTokenExpired,
    this.onRevoked,
    this.backoffBase = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 60),
    this.requestTimeout = const Duration(seconds: 10),
    Random? random,
  }) : _rng = random ?? Random();

  final Uri url;
  final Uint8List deviceId;
  final Platform platform;
  final String Function() accessToken;
  final Uint8List Function() inboxCursor;

  /// Xử lý một Deliver. Chỉ khi hàm này xong (đã ghi bền) client mới gửi Ack. Gọi tuần tự theo thứ tự nhận.
  final Future<void> Function(Deliver) onDeliver;

  /// Gọi khi đóng với 4002 (token hết hạn): làm mới token rồi client tự kết nối lại.
  final Future<void> Function()? onTokenExpired;

  /// Gọi khi đóng với 4003 (thiết bị bị thu hồi): app xóa dữ liệu và về màn đăng nhập.
  final void Function()? onRevoked;

  final Duration backoffBase, backoffMax, requestTimeout;
  final Random _rng;

  GatewayState state = GatewayState.disconnected;
  final _stateCtl = StreamController<GatewayState>.broadcast();
  Stream<GatewayState> get states => _stateCtl.stream;

  /// Mã đóng gần nhất (để test và log).
  int? lastCloseCode;

  WebSocketChannel? _ch;
  bool _stopped = false;
  var _nextReq = 1;
  final _pending = <int, Completer<SendResult>>{};
  Timer? _heartbeat;
  DateTime _lastFrame = DateTime.now();
  Future<void>? _loop;

  void _set(GatewayState s) {
    state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  /// Bắt đầu vòng kết nối (tự kết nối lại tới khi [stop]).
  void start() {
    if (_loop != null) return;
    _stopped = false;
    _loop = _run();
  }

  Future<void> stop() async {
    _stopped = true;
    _heartbeat?.cancel();
    await _ch?.sink.close(1000);
    await _loop;
    _loop = null;
    _set(GatewayState.stopped);
  }

  /// Chờ tới khi online (đã nhận SyncDone).
  Future<void> whenOnline({Duration timeout = const Duration(seconds: 15)}) async {
    if (state == GatewayState.online) return;
    await states.firstWhere((s) => s == GatewayState.online).timeout(timeout);
  }

  Future<void> _run() async {
    var attempt = 0;
    while (!_stopped) {
      var reachedOnline = false;
      try {
        reachedOnline = await _session();
      } on Object {
        // lỗi mạng/giao thức: rơi xuống backoff
      }
      if (_stopped) break;
      if (reachedOnline) attempt = 0;
      switch (lastCloseCode) {
        case 4003:
          onRevoked?.call();
          _set(GatewayState.stopped);
          return;
        case 4004 || 4010:
          _set(GatewayState.disconnected); // không tự kết nối lại
          return;
        case 4002:
          try {
            await onTokenExpired?.call();
          } on Object {
            // làm mới thất bại: backoff rồi thử lại
          }
      }
      _set(GatewayState.backoff);
      await Future<void>.delayed(_delay(attempt++));
    }
  }

  /// Backoff gấp đôi từ [backoffBase] tới [backoffMax], cộng jitter ±50% (giao-thuc.md mục 3).
  Duration _delay(int attempt) {
    final base = min(backoffBase.inMilliseconds * pow(2, min(attempt, 20)), backoffMax.inMilliseconds.toDouble());
    return Duration(milliseconds: (base * (0.5 + _rng.nextDouble())).round());
  }

  /// Một lần kết nối. Trả true nếu đã tới trạng thái online.
  Future<bool> _session() async {
    lastCloseCode = null;
    _set(GatewayState.connecting);
    final ch = WebSocketChannel.connect(url, protocols: const ['chat.v1']);
    _ch = ch;
    var online = false;
    try {
      await ch.ready;
      _set(GatewayState.authenticating);
      _lastFrame = DateTime.now();
      ch.sink.add(ClientFrame(
        hello: Hello(
          protoVersion: 1,
          deviceId: deviceId,
          accessToken: accessToken(),
          inboxCursor: inboxCursor(),
          platform: platform,
        ),
      ).writeToBuffer());

      await for (final data in ch.stream) {
        _lastFrame = DateTime.now();
        final f = ServerFrame.fromBuffer(data as List<int>);
        switch (f.whichBody()) {
          case ServerFrame_Body.welcome:
            _set(GatewayState.syncing);
            final hb = f.welcome.heartbeatMs == 0 ? 25000 : f.welcome.heartbeatMs;
            _heartbeat?.cancel();
            _heartbeat = Timer.periodic(Duration(milliseconds: hb), (_) => _tick(ch, hb));
          case ServerFrame_Body.deliver:
            final d = f.deliver;
            await onDeliver(d); // ghi bền xong mới Ack (giao-thuc.md 3)
            if (d.inboxId.isNotEmpty) {
              ch.sink.add(ClientFrame(ack: Ack(inboxIds: [d.inboxId])).writeToBuffer());
            }
          case ServerFrame_Body.syncDone:
            online = true;
            _set(GatewayState.online);
          case ServerFrame_Body.sendResult:
            _pending.remove(f.reqId.toInt())?.complete(f.sendResult);
          case ServerFrame_Body.error:
            final e = f.error;
            _pending.remove(f.reqId.toInt())?.completeError(GatewayException(e.message,
                code: e.code, currentEpoch: e.currentEpoch.toInt(), retryAfterMs: e.retryAfterMs));
          default:
            break; // Pong, presence, receipt, incoming_call: chưa dùng
        }
      }
    } finally {
      _heartbeat?.cancel();
      lastCloseCode = ch.closeCode;
      for (final c in _pending.values) {
        c.completeError(GatewayException('mất kết nối'));
      }
      _pending.clear();
      _ch = null;
      if (!_stopped) _set(GatewayState.disconnected);
    }
    return online;
  }

  void _tick(WebSocketChannel ch, int hbMs) {
    // Không nhận khung nào trong hai chu kỳ thì đóng (giao-thuc.md mục 3).
    if (DateTime.now().difference(_lastFrame).inMilliseconds > 2 * hbMs) {
      ch.sink.close(4000, 'heartbeat timeout');
      return;
    }
    ch.sink.add(ClientFrame(ping: Ping()).writeToBuffer());
  }

  /// Gửi một tin APPLICATION. Ném [GatewayException] nếu offline, quá hạn, hoặc server trả lỗi.
  Future<SendResult> send(SendMessage m) {
    final ch = _ch;
    if (ch == null || state != GatewayState.online) {
      return Future.error(GatewayException('chưa kết nối'));
    }
    final id = _nextReq++;
    final c = Completer<SendResult>();
    _pending[id] = c;
    ch.sink.add(ClientFrame(reqId: Int64(id), send: m).writeToBuffer());
    return c.future.timeout(requestTimeout, onTimeout: () {
      _pending.remove(id);
      throw GatewayException('quá hạn phản hồi');
    });
  }
}
