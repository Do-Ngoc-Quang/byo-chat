import 'package:flutter/foundation.dart';

import '../core/chatcore.dart';
import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/services.pb.dart';
import '../net/api.dart';
import '../net/connect_client.dart';
import '../storage/session_store.dart';
import 'session.dart';
import 'uuid7.dart';

export 'session.dart';

enum LoginStep { contact, code, registering, done }

/// Luồng đăng nhập OTP rồi đăng ký thiết bị đầu tiên (giao-thuc.md 6.1):
/// RequestOtp -> VerifyOtp -> sinh khóa + credential + KeyPackage trong chatcore -> RegisterDevice.
/// Tài khoản đã có (không phải thiết bị đầu tiên) cần liên kết thiết bị hoặc khôi phục (giai đoạn 4).
class LoginController extends ChangeNotifier {
  LoginController({
    required this.api,
    required this.openCore,
    this.store,
    Platform? platform,
    DateTime Function()? now,
  })  : platform = platform ?? _hostPlatform(),
        _now = now ?? DateTime.now;

  final ChatApi api;
  final Future<ChatCore> Function() openCore;

  /// Nơi lưu bền khóa và phiên; null thì phiên chỉ sống trong bộ nhớ (test).
  final SessionStore? store;
  final Platform platform;
  final DateTime Function() _now;

  LoginStep step = LoginStep.contact;
  bool busy = false;
  String? error;

  /// Số mili giây nên chờ trước khi xin mã mới (từ `retry_after_ms`).
  int retryAfterMs = 0;
  Session? session;

  List<int>? _challengeId;
  Uint8List? _ticket;
  Uint8List? _accountId;

  static Platform _hostPlatform() {
    if (kIsWeb) return Platform.PLATFORM_WEB;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => Platform.PLATFORM_ANDROID,
      TargetPlatform.iOS => Platform.PLATFORM_IOS,
      TargetPlatform.macOS => Platform.PLATFORM_MACOS,
      TargetPlatform.windows => Platform.PLATFORM_WINDOWS,
      _ => Platform.PLATFORM_LINUX,
    };
  }

  /// Chạy một thao tác có trạng thái bận và báo lỗi tiếng Việt thay vì ném ra giao diện.
  Future<void> _run(Future<void> Function() body) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } on ConnectException catch (e) {
      error = describeError(e);
      retryAfterMs = e.retryAfterMs;
    } on ChatCoreException catch (e) {
      error = 'Lỗi lõi mã hóa: ${e.message}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> requestOtp(OtpChannel channel, String destination) => _run(() async {
        final r = await api.requestOtp(RequestOtpRequest(channel: channel, destination: destination.trim()));
        _challengeId = r.challengeId;
        retryAfterMs = r.retryAfterMs;
        step = LoginStep.code;
      });

  /// Nhập mã. Đúng thì đi tiếp tới đăng ký thiết bị ngay.
  Future<void> verifyCode(String code) => _run(() async {
        final id = _challengeId ?? (throw StateError('chưa xin mã'));
        final v = await api.verifyOtp(VerifyOtpRequest(challengeId: id, code: code.trim()));
        _ticket = Uint8List.fromList(v.sessionTicket);
        _accountId = Uint8List.fromList(v.accountId);
        if (!v.isNewAccount) {
          // Thiết bị này chưa giữ khóa danh tính của tài khoản đã có: cần liên kết hoặc khôi phục.
          _ticket = null;
          step = LoginStep.contact;
          error = 'Tài khoản này đã có thiết bị khác. Liên kết thiết bị hoặc khôi phục sẽ có ở bản sau.';
          return;
        }
        step = LoginStep.registering;
        notifyListeners();
        await _register();
      });

  /// Thử lại đăng ký sau khi lỗi (ticket còn dùng được vì server chỉ tiêu thụ khi thành công).
  Future<void> retryRegister() => _run(_register);

  /// Khôi phục phiên đã lưu khi mở app. true nếu đã vào được phiên.
  Future<bool> restore() async {
    final st = store;
    if (st == null) return false;
    busy = true;
    notifyListeners();
    try {
      final s = await st.restore(api, openCore);
      if (s != null) session = s;
      return s != null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Đăng xuất: xóa khóa và trạng thái của thiết bị này. Tài khoản đã có thì vào lại cần liên kết/khôi phục.
  Future<void> logout() async {
    final s = session;
    session = null;
    api.client.accessToken = null;
    step = LoginStep.contact;
    await s?.core.dispose();
    await store?.clear();
    notifyListeners();
  }

  void backToContact() {
    step = LoginStep.contact;
    error = null;
    notifyListeners();
  }

  Future<void> _register() async {
    final ticket = _ticket ?? (throw StateError('chưa có ticket'));
    final accountId = _accountId!;
    final deviceId = newUuidV7(now: _now());
    final core = await openCore();
    try {
      await core.openDevice(accountId: accountId, deviceId: deviceId, createdMs: _now().millisecondsSinceEpoch);
      final cred = await core.deviceCredential();
      final kps = await core.keyPackages(100); // spec 6.1 bước 4
      final last = await core.lastResortKeyPackage();
      final resp = await api.registerDevice(RegisterDeviceRequest(
        sessionTicket: ticket,
        deviceId: deviceId,
        platform: platform,
        deviceName: _deviceName(),
        devicePublicKey: cred.devicePublicKey,
        credential: cred.credential,
        accountIdentityPublicKey: cred.identityPublicKey, // thiết bị đầu tiên
        keyPackages: kps,
        lastResortKeyPackage: last,
      ));
      api.client.accessToken = resp.tokens.accessToken;
      final count = await api.countKeyPackages();
      final s = Session(accountId, deviceId, core, resp.tokens, count.remaining);
      // Ghi bền TRƯỚC khi báo đã đăng nhập: server đã tiêu thụ ticket, mất khóa lúc này là mất thiết bị.
      await store?.save(s);
      session = s;
      _ticket = null;
      step = LoginStep.done;
    } catch (_) {
      await core.dispose(); // lần thử lại sẽ dựng lõi mới
      rethrow;
    }
  }

  String _deviceName() => switch (platform) {
        Platform.PLATFORM_ANDROID => 'Android',
        Platform.PLATFORM_WEB => 'Web',
        _ => 'Thiết bị',
      };
}

/// Thông báo tiếng Việt cho người dùng theo bảng mã lỗi ở giao-thuc.md mục 5.
String describeError(ConnectException e) {
  switch (e.errorCode) {
    case ErrorCode.ERROR_CODE_RATE_LIMITED:
      final s = (e.retryAfterMs / 1000).ceil();
      return s > 0 ? 'Thao tác quá nhanh, thử lại sau $s giây.' : 'Quá số lần cho phép, hãy xin mã mới.';
    case ErrorCode.ERROR_CODE_INVALID_ARGUMENT:
      return e.message.isNotEmpty ? e.message : 'Dữ liệu không hợp lệ.';
    case ErrorCode.ERROR_CODE_UNAUTHENTICATED:
      return 'Phiên đã hết hạn, hãy đăng nhập lại.';
    case ErrorCode.ERROR_CODE_UNAVAILABLE:
      return 'Máy chủ đang bận, thử lại sau.';
    default:
      return e.code == 'unavailable' ? 'Không kết nối được máy chủ.' : 'Lỗi: ${e.message}';
  }
}
