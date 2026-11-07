// Lưu bền với server THẬT và lõi THẬT: đăng nhập, tạo nhóm MLS, "tắt app", mở lại bằng kho đã lưu.
// Dùng chung cho VM (kho bí mật trong bộ nhớ), Android (Keystore thật) và Web (kho thật của trình duyệt).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:byo_chat/storage/session_store.dart';

void _check(bool ok, String msg) {
  if (!ok) throw StateError('persist e2e sai: $msg');
}

Future<void> runPersistE2E(Uri serverUrl, SecretStore secrets, BlobStore blobs) async {
  final store = SessionStore(secrets: secrets, blobs: blobs);
  await store.clear(); // bắt đầu sạch (kho thật của máy có thể còn dữ liệu cũ)
  _check(await store.restore(ChatApi(ConnectClient(serverUrl)), openChatCore) == null, 'kho sạch thì không có phiên');

  // 1. Đăng nhập thật (số mới mỗi lần chạy), tạo nhóm MLS rồi ghi bền.
  final api1 = ChatApi(ConnectClient(serverUrl));
  final login = LoginController(api: api1, openCore: openChatCore, store: store);
  await login.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+8490${1000000 + Random().nextInt(8999999)}');
  await login.verifyCode('123456');
  _check(login.step == LoginStep.done, 'đăng nhập: ${login.error}');
  final s1 = login.session!;
  final conv = Uint8List.fromList(utf8.encode('nhom-luu-ben'));
  await s1.core.createGroup(conv);
  final gi1 = await s1.core.groupInfo(conv);
  await store.save(s1); // mọi thay đổi trạng thái MLS phải kết thúc bằng save
  final deviceHex = base64.encode(s1.deviceId);
  await s1.core.dispose(); // "tắt app": hủy lõi trong bộ nhớ

  // 2. "Mở lại app": ChatApi mới (chưa có token), lõi mới, chỉ có kho đã lưu.
  final api2 = ChatApi(ConnectClient(serverUrl));
  final s2 = await store.restore(api2, openChatCore);
  _check(s2 != null, 'phải khôi phục được phiên');
  _check(base64.encode(s2!.deviceId) == deviceHex, 'phải cùng thiết bị');
  _check(api2.client.accessToken != null, 'phải có token sau khi khôi phục');

  // nhóm còn nguyên: cùng epoch, vẫn mã hóa được, GroupInfo mới vẫn dựng được
  _check(await s2.core.epoch(conv) == 0, 'epoch nhóm phải giữ nguyên');
  await s2.core.encrypt(conv, Uint8List.fromList(utf8.encode('xin chào sau khi mở lại')));
  _check((await s2.core.groupInfo(conv)).length == gi1.length, 'GroupInfo phải dựng lại được');

  // khóa riêng của KeyPackage đã tải lên server trước khi tắt app vẫn dùng được: người khác Fetch
  // gói của ta, thêm ta vào nhóm, và lõi đã khôi phục vào được nhóm đó.
  final fetched = await api2.fetchKeyPackages(FetchKeyPackagesRequest(accountIds: [s2.accountId]));
  final dev = fetched.accounts.single.devices.single;
  final peer = await openChatCore();
  await peer.openDevice(accountId: Uint8List.fromList(List.filled(16, 9)), deviceId: Uint8List.fromList(List.filled(16, 8)), createdMs: DateTime.now().millisecondsSinceEpoch);
  await peer.createGroup(Uint8List.fromList(utf8.encode('nhom-cua-peer')));
  final out = await peer.addMembers(Uint8List.fromList(utf8.encode('nhom-cua-peer')), [Uint8List.fromList(dev.keyPackage)]);
  await s2.core.joinWelcome(Uint8List.fromList(utf8.encode('nhom-cua-peer')), out.welcome);
  final ct = await peer.encrypt(Uint8List.fromList(utf8.encode('nhom-cua-peer')), Uint8List.fromList(utf8.encode('chào bạn')));
  _check(utf8.decode(await s2.core.decrypt(Uint8List.fromList(utf8.encode('nhom-cua-peer')), ct)) == 'chào bạn', 'giải mã sau khi vào nhóm');
  await peer.dispose();

  // token dùng được với server thật sau khi khôi phục
  _check((await api2.countKeyPackages()).remaining >= 98, 'token khôi phục phải gọi được server');

  // 3. Xóa snapshot thì không còn khôi phục được (và dọn sạch phần còn lại).
  await blobs.delete('core.snapshot');
  _check(await store.restore(ChatApi(ConnectClient(serverUrl)), openChatCore) == null, 'thiếu snapshot thì không có phiên');
  _check(!await store.exists(), 'phải dọn sạch');
  await s2.core.dispose();
}
