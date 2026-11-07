// Kịch bản đầu-cuối với server THẬT: đăng nhập OTP, đăng ký thiết bị, KeyPackage, refresh token.
// Yêu cầu server chạy với CHAT_DEV_OTP=1 CHAT_DEV_OTP_CODE=123456 (và CHAT_CORS_ORIGINS khi chạy trên Web).
// Dùng chung cho test VM, Android emulator và Web (chỉ dùng dart:core, không phụ thuộc flutter_test).
import 'dart:math';
import 'dart:typed_data';

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';

void _check(bool ok, String msg) {
  if (!ok) throw StateError('e2e sai: $msg');
}

Future<void> runLoginE2E(Uri serverUrl) async {
  final api = ChatApi(ConnectClient(serverUrl));
  final phone = '+8490${(1000000 + Random().nextInt(8999999))}'; // số mới mỗi lần chạy
  final login = LoginController(api: api, openCore: openChatCore);

  await login.requestOtp(OtpChannel.OTP_CHANNEL_SMS, phone);
  _check(login.step == LoginStep.code, 'RequestOtp: ${login.error}');
  await login.verifyCode('000000');
  _check(login.step == LoginStep.code && login.error != null, 'mã sai phải bị từ chối');
  await login.verifyCode('123456');
  _check(login.step == LoginStep.done, 'đăng nhập: ${login.error}');
  final s = login.session!;
  _check(s.remainingKeyPackages == 100, 'server phải giữ 100 gói một lần, có ${s.remainingKeyPackages}');
  _check(s.tokens.accessToken.isNotEmpty && s.tokens.refreshToken.isNotEmpty, 'thiếu token');

  // Lấy KeyPackage của chính mình từ server rồi để lõi kiểm (spec 6.2 bước 2).
  final f = await api.fetchKeyPackages(FetchKeyPackagesRequest(accountIds: [s.accountId]));
  _check(f.accounts.length == 1 && f.accounts[0].devices.length == 1, 'FetchKeyPackages sai cấu trúc');
  final acct = f.accounts[0];
  final dev = acct.devices[0];
  _check(!dev.lastResort, 'còn gói một lần, không được trả last resort');
  await s.core.verifyKeyPackage(
    keyPackage: Uint8List.fromList(dev.keyPackage),
    credential: Uint8List.fromList(dev.credential),
    identityPublicKey: Uint8List.fromList(acct.accountIdentityPublicKey),
    expectedAccountId: s.accountId,
  );
  _check((await api.countKeyPackages()).remaining == 99, 'Fetch phải tiêu thụ đúng 1 gói');

  // Refresh token xoay vòng: token cũ hết hiệu lực.
  final p2 = await api.refreshToken(RefreshTokenRequest(deviceId: s.deviceId, refreshToken: s.tokens.refreshToken));
  _check(p2.refreshToken != s.tokens.refreshToken, 'refresh token phải đổi');
  try {
    await api.refreshToken(RefreshTokenRequest(deviceId: s.deviceId, refreshToken: s.tokens.refreshToken));
    throw StateError('refresh token cũ phải bị từ chối');
  } on ConnectException catch (e) {
    _check(e.code == 'unauthenticated', 'mã lỗi ${e.code}');
  }

  // Cùng số điện thoại đăng nhập lại: tài khoản đã có, thiết bị này chưa có khóa danh tính.
  final again = LoginController(api: ChatApi(ConnectClient(serverUrl)), openCore: openChatCore);
  await again.requestOtp(OtpChannel.OTP_CHANNEL_SMS, phone);
  await again.verifyCode('123456');
  _check(again.session == null && again.step == LoginStep.contact && again.error != null, 'tài khoản đã có phải bị chặn');

  await s.core.dispose();
}
