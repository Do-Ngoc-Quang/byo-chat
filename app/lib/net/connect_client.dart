import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:protobuf/protobuf.dart';

import '../gen/chat/v1/common.pb.dart' as pb;
import '../gen/chat/v1/common.pbenum.dart' show ErrorCode;

/// Lỗi trả về từ server theo Connect (giao-thuc.md mục 5). `code` là mã Connect
/// (ví dụ `unauthenticated`); `detail` là `chat.v1.Error` đính kèm nếu có.
class ConnectException implements Exception {
  ConnectException(this.code, this.message, {this.detail, this.httpStatus});

  final String code;
  final String message;
  final pb.Error? detail;
  final int? httpStatus;

  ErrorCode? get errorCode => detail?.code;
  int get retryAfterMs => detail?.retryAfterMs ?? 0;

  @override
  String toString() => 'ConnectException($code: $message)';
}

/// Client Connect unary rất mỏng (giao thức Connect, nội dung Protobuf nhị phân). Dùng chung
/// cho mọi dịch vụ `chat.v1`; header `Authorization` do `accessToken` cấp khi có.
class ConnectClient {
  ConnectClient(this.baseUrl, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final http.Client _http;

  /// Token truy cập hiện tại; null khi chưa đăng nhập.
  String? accessToken;

  Future<Res> unary<Req extends GeneratedMessage, Res extends GeneratedMessage>(
    String service,
    String method,
    Req request,
    Res Function() makeResponse, {
    String? idempotencyKey,
  }) async {
    final url = baseUrl.replace(path: '${baseUrl.path.replaceAll(RegExp(r'/$'), '')}/chat.v1.$service/$method');
    final headers = {
      'Content-Type': 'application/proto',
      'Connect-Protocol-Version': '1',
      'Authorization': ?(accessToken == null ? null : 'Bearer $accessToken'),
      'Idempotency-Key': ?idempotencyKey,
    };
    final http.Response resp;
    try {
      resp = await _http.post(url, headers: headers, body: request.writeToBuffer());
    } on Exception catch (e) {
      // Mất mạng, từ chối kết nối, CORS...: coi như dịch vụ không sẵn sàng (thử lại được).
      throw ConnectException('unavailable', 'Không kết nối được máy chủ: $e');
    }
    if (resp.statusCode == 200) {
      return makeResponse()..mergeFromBuffer(resp.bodyBytes);
    }
    throw _parseError(resp);
  }

  /// Lỗi Connect là JSON: {code, message, details:[{type, value(base64)}]}.
  ConnectException _parseError(http.Response resp) {
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      pb.Error? detail;
      for (final d in (j['details'] as List? ?? const [])) {
        if ((d as Map)['type'] == 'chat.v1.Error') {
          // base64 chuẩn, có thể thiếu đệm '='
          final v = d['value'] as String;
          detail = pb.Error()..mergeFromBuffer(base64.decode(base64.normalize(v)));
        }
      }
      return ConnectException(j['code'] as String? ?? 'unknown', j['message'] as String? ?? '',
          detail: detail, httpStatus: resp.statusCode);
    } on Exception {
      return ConnectException('unknown', 'Phản hồi lỗi không đọc được (HTTP ${resp.statusCode})', httpStatus: resp.statusCode);
    }
  }

  void close() => _http.close();
}
