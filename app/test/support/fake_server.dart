import 'dart:convert';
import 'dart:typed_data';

import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/common.pb.dart' as pb;
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:fixnum/fixnum.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Máy chủ giả theo giao thức Connect (chỉ vài RPC) để test luồng đăng nhập không cần mạng.
class FakeServer {
  FakeServer({this.newAccount = true});

  final bool newAccount;
  final calls = <String>[];
  RegisterDeviceRequest? registered;
  int failRegister = 0; // số lần RegisterDevice đầu bị từ chối
  int? rateLimitMs; // RequestOtp trả RATE_LIMITED kèm retry_after
  int accessTtlMs = 15 * 60 * 1000; // hạn access token cấp ra
  String refreshMode = 'ok'; // ok | revoked | down
  int refreshes = 0;

  late final MockClient client = MockClient(_handle);

  ChatApi get api => ChatApi(ConnectClient(Uri.parse('http://fake.test'), httpClient: client));

  http.Response _err(int status, String code, ErrorCode ec, String msg, {int retryMs = 0}) {
    final detail = pb.Error(code: ec, message: msg, retryAfterMs: retryMs).writeToBuffer();
    return http.Response(
      jsonEncode({
        'code': code,
        'message': msg,
        'details': [
          {'type': 'chat.v1.Error', 'value': base64.encode(detail).replaceAll('=', '')},
        ],
      }),
      status,
      headers: {'content-type': 'application/json'},
    );
  }

  http.Response _ok(List<int> body) => http.Response.bytes(body, 200, headers: {'content-type': 'application/proto'});

  Future<http.Response> _handle(http.Request r) async {
    final method = r.url.path.split('/').last;
    calls.add(method);
    expectHeaders(r);
    switch (method) {
      case 'RequestOtp':
        if (rateLimitMs != null) {
          return _err(429, 'resource_exhausted', ErrorCode.ERROR_CODE_RATE_LIMITED, 'quá nhanh', retryMs: rateLimitMs!);
        }
        final q = RequestOtpRequest()..mergeFromBuffer(r.bodyBytes);
        if (!q.destination.startsWith('+')) {
          return _err(400, 'invalid_argument', ErrorCode.ERROR_CODE_INVALID_ARGUMENT, 'kênh hoặc đích không hợp lệ');
        }
        return _ok(RequestOtpResponse(challengeId: List.filled(16, 7), retryAfterMs: 30000).writeToBuffer());
      case 'VerifyOtp':
        final q = VerifyOtpRequest()..mergeFromBuffer(r.bodyBytes);
        if (q.code != '123456') {
          return _err(400, 'invalid_argument', ErrorCode.ERROR_CODE_INVALID_ARGUMENT, 'mã không đúng hoặc đã hết hạn');
        }
        return _ok(VerifyOtpResponse(
                accountId: List.filled(16, 1), isNewAccount: newAccount, sessionTicket: List.filled(32, 9))
            .writeToBuffer());
      case 'RegisterDevice':
        if (failRegister > 0) {
          failRegister--;
          return _err(503, 'unavailable', ErrorCode.ERROR_CODE_UNAVAILABLE, 'lỗi nội bộ');
        }
        registered = RegisterDeviceRequest()..mergeFromBuffer(r.bodyBytes);
        return _ok(RegisterDeviceResponse(tokens: TokenPair(accessToken: 'tok', refreshToken: 'ref', accessExpiresMs: Int64(DateTime.now().millisecondsSinceEpoch + accessTtlMs))).writeToBuffer());
      case 'RefreshToken':
        refreshes++;
        if (refreshMode == 'down') return _err(503, 'unavailable', ErrorCode.ERROR_CODE_UNAVAILABLE, 'lỗi nội bộ');
        final q = RefreshTokenRequest()..mergeFromBuffer(r.bodyBytes);
        if (refreshMode == 'revoked' || q.refreshToken != 'ref') {
          return _err(401, 'unauthenticated', ErrorCode.ERROR_CODE_UNAUTHENTICATED, 'refresh token không hợp lệ');
        }
        return _ok(TokenPair(accessToken: 'tok', refreshToken: 'ref2', accessExpiresMs: Int64(DateTime.now().millisecondsSinceEpoch + 900000)).writeToBuffer());
      case 'CountKeyPackages':
        if (r.headers['authorization'] != 'Bearer tok') {
          return _err(401, 'unauthenticated', ErrorCode.ERROR_CODE_UNAUTHENTICATED, 'thiếu token');
        }
        return _ok(KeyPackageCount(remaining: registered?.keyPackages.length ?? 0).writeToBuffer());
    }
    return http.Response('', 404);
  }

  void expectHeaders(http.Request r) {
    if (r.headers['content-type'] != 'application/proto' || r.headers['connect-protocol-version'] != '1') {
      throw StateError('thiếu header Connect: ${r.headers}');
    }
  }
}

/// Lõi giả: trả credential/KeyPackage đúng kích thước, không chạy MLS thật.
class FakeCore implements ChatCore {
  bool disposed = false;
  Uint8List? openedWith;

  @override
  Future<String> version() async => '9.9.9';
  @override
  Future<void> open(Uint8List identity) async {}
  @override
  Future<void> openDeviceRaw(Uint8List packedArgs) async => openedWith = packedArgs;
  @override
  Future<void> openRestoreRaw(Uint8List packedArgs) async {
    final a = unpackList(packedArgs);
    if (a[1].length != 32 || !_same(a[0], snapshotBytes)) throw ChatCoreException('giải mã snapshot thất bại');
    restored = true;
  }

  static Uint8List snapshotBytes = Uint8List.fromList(List.filled(40, 5));
  bool restored = false;
  int snapshots = 0;

  static bool _same(Uint8List a, Uint8List b) => a.length == b.length && Iterable.generate(a.length).every((i) => a[i] == b[i]);

  @override
  Future<Uint8List> callRaw(String op, Uint8List packedArgs) async {
    Uint8List b(int n, int v) => Uint8List.fromList(List.filled(n, v));
    switch (op) {
      case 'credential':
        return packList([b(136, 1), b(32, 2), b(32, 3)]);
      case 'key_packages':
        final n = ByteData.sublistView(unpackList(packedArgs)[0]).getUint32(0, Endian.little);
        return packList([for (var i = 0; i < n; i++) b(10, i)]);
      case 'snapshot':
        snapshots++;
        return packList([snapshotBytes]);
      case 'last_resort_key_package':
        return packList([b(10, 99)]);
    }
    throw ChatCoreException('op không có trong lõi giả: $op');
  }

  @override
  Future<void> dispose() async => disposed = true;
}
