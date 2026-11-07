import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../auth/session.dart';
import '../core/chatcore.dart';
import '../gen/chat/v1/services.pb.dart';
import '../net/api.dart';
import '../net/connect_client.dart';
import 'blob_store.dart';
import 'secret_store.dart';

/// Lưu bền phiên đăng nhập và trạng thái MLS (ADR 0008):
/// - khóa mã hóa snapshot (32 byte ngẫu nhiên) và token: trong [SecretStore] (Keystore trên Android);
/// - snapshot do chatcore mã hóa AES-256-GCM: trong [BlobStore].
/// Mất khóa hoặc blob thì không khôi phục được (phải đăng nhập lại như thiết bị mới).
class SessionStore {
  SessionStore({required this.secrets, required this.blobs, this.namespace = '', DateTime Function()? now, Random? random})
      : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final SecretStore secrets;
  final BlobStore blobs;

  /// Tiền tố tên khóa/tệp, để nhiều phiên cùng tồn tại trong một kho (test, sau này đa tài khoản).
  final String namespace;
  final DateTime Function() _now;
  final Random _random;

  String get _keyName => '${namespace}byo.snapshot-key';
  String get _metaName => '${namespace}byo.session';
  String get _blobName => '${namespace}core.snapshot';

  /// Còn dưới ngần này thì làm mới access token khi khôi phục.
  static const refreshMargin = Duration(minutes: 1);

  Future<Uint8List> _key() async {
    final s = await secrets.read(_keyName);
    if (s != null) return base64.decode(s);
    final k = Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));
    await secrets.write(_keyName, base64.encode(k));
    return k;
  }

  /// Ghi snapshot rồi metadata. Thứ tự này đảm bảo: metadata (có refresh token mới) chỉ xuất hiện khi
  /// snapshot tương ứng đã nằm trên đĩa; mất điện giữa hai bước thì lần khởi động sau vẫn khôi phục
  /// được từ snapshot mới với refresh token cũ (còn hiệu lực tới khi bị xoay).
  Future<void> save(Session s) async {
    final sealed = await s.core.snapshot(await _key());
    await blobs.write(_blobName, sealed);
    await secrets.write(
      _metaName,
      jsonEncode({
        'v': 1,
        'account': base64.encode(s.accountId),
        'device': base64.encode(s.deviceId),
        'access': s.tokens.accessToken,
        'refresh': s.tokens.refreshToken,
        'accessExpiresMs': s.tokens.accessExpiresMs.toInt(),
        'kp': s.remainingKeyPackages,
      }),
    );
  }

  Future<bool> exists() async => await secrets.read(_metaName) != null;

  /// Khôi phục phiên. null nếu không có gì lưu, hoặc dữ liệu không dùng được (sẽ bị xóa) hoặc server
  /// báo thiết bị đã bị thu hồi / refresh token vô hiệu. Mất mạng: vẫn trả phiên (token có thể cũ).
  Future<Session?> restore(ChatApi api, Future<ChatCore> Function() openCore) async {
    final metaRaw = await secrets.read(_metaName);
    final keyRaw = await secrets.read(_keyName);
    final blob = await blobs.read(_blobName);
    if (metaRaw == null) return null;
    if (keyRaw == null || blob == null) {
      await clear(); // mất một nửa: không khôi phục được
      return null;
    }
    final ChatCore core = await openCore();
    final Session s;
    try {
      final m = jsonDecode(metaRaw) as Map<String, dynamic>;
      await core.openRestore(blob, base64.decode(keyRaw));
      s = Session(
        base64.decode(m['account'] as String),
        base64.decode(m['device'] as String),
        core,
        TokenPair(
          accessToken: m['access'] as String,
          refreshToken: m['refresh'] as String,
          accessExpiresMs: Int64(m['accessExpiresMs'] as int),
        ),
        m['kp'] as int,
      );
    } on Exception {
      // snapshot hỏng / sai khóa / metadata lỗi
      await core.dispose();
      await clear();
      return null;
    }
    api.client.accessToken = s.tokens.accessToken;
    final msLeft = s.tokens.accessExpiresMs.toInt() - _now().millisecondsSinceEpoch;
    if (msLeft < refreshMargin.inMilliseconds) {
      try {
        s.tokens = await api.refreshToken(RefreshTokenRequest(deviceId: s.deviceId, refreshToken: s.tokens.refreshToken));
        api.client.accessToken = s.tokens.accessToken;
        await save(s); // refresh token đã xoay: phải ghi ngay kẻo mất
      } on ConnectException catch (e) {
        if (e.code == 'unavailable') return s; // offline: dùng tiếp, thử lại sau
        await core.dispose();
        await clear(); // bị thu hồi hoặc token vô hiệu
        api.client.accessToken = null;
        return null;
      }
    }
    return s;
  }

  /// Xóa mọi thứ của thiết bị này (đăng xuất, hoặc bị thu hồi: mã đóng 4003).
  Future<void> clear() async {
    await secrets.delete(_metaName);
    await secrets.delete(_keyName);
    await blobs.delete(_blobName);
  }
}
