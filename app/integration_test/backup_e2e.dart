// Sao lưu và khôi phục tài khoản (giao-thuc.md 6.14) với server THẬT (cần CHAT_DEV_BLOB_URL phía server):
// Alice có 1-1 và nhóm với Bob, sao lưu, mất máy, đăng nhập lại bằng OTP, khôi phục bằng recovery key, giữ lịch sử,
// tự vào lại hai hội thoại bằng External Commit, thu hồi thiết bị đã mất, rồi nói chuyện tiếp với Bob.
import 'dart:async';
import 'dart:typed_data';

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/chat/backup.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:byo_chat/storage/session_store.dart';

import 'chat_e2e.dart';

void _check(bool ok, String msg) {
  if (!ok) throw StateError('backup e2e sai: $msg');
}

Future<void> _waitFor(String what, bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('backup e2e quá hạn khi chờ: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> runBackupE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'balice.');
  final bob = await signUpForTest(serverUrl, 'bbob.');
  await alice.startEngine();
  await bob.startEngine();
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final dm = await alice.engine.openDirect(sms, bob.phone);
  final grp = await alice.engine.createGroup('Nhóm sao lưu', [(sms, bob.phone)]);
  await _waitFor('Bob vào hai hội thoại', () => bob.engine.conversations.length == 2);
  await alice.engine.sendText(dm.hexId, 'lịch sử trước khi mất máy');
  await alice.engine.sendText(grp.hexId, 'nhóm: lịch sử cũ');
  final bobDm = bob.engine.conversations.firstWhere((c) => !c.isGroup);
  final bobGrp = bob.engine.conversations.firstWhere((c) => c.isGroup);
  await _waitFor('Bob nhận', () => bob.msgs(bobDm).isNotEmpty && bob.msgs(bobGrp).isNotEmpty);

  // 1. Sao lưu; recovery key hiển thị dạng chuỗi và đọc lại được.
  final svc = BackupService(api: alice.api);
  final key = await svc.backUp(alice.session);
  final shown = BackupService.formatKey(key);
  _check(shown.length == 64 + 15 && RegExp(r'^([0-9a-f]{4}-){15}[0-9a-f]{4}$').hasMatch(shown), 'định dạng recovery key: $shown');
  _check(BackupService.parseKey(shown).join(',') == key.join(','), 'đọc lại recovery key');
  var badFormat = false;
  try {
    BackupService.parseKey('abc');
  } on BackupException {
    badFormat = true;
  }
  _check(badFormat, 'recovery key sai định dạng bị từ chối');
  final oldDevice = alice.session.deviceId;
  final oldAccount = alice.session.accountId;

  // 2. Mất máy: tắt hẳn, xóa kho. Máy cũ vẫn là thiết bị còn hiệu lực ở server.
  await alice.engine.stop();
  await alice.session.core.dispose();
  await alice.store.clear();

  // 3. Máy mới: OTP cho tài khoản đã có (chờ qua khoảng cách giữa hai lần xin mã).
  final api2 = ChatApi(ConnectClient(serverUrl));
  final store2 = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore(), namespace: 'balice2.');
  final login = LoginController(api: api2, openCore: openChatCore, store: store2);
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (true) {
    await login.requestOtp(sms, alice.phone);
    if (login.step == LoginStep.code) break;
    _check(DateTime.now().isBefore(end) && login.retryAfterMs > 0, 'xin OTP lần hai: ${login.error}');
    await Future<void>.delayed(Duration(milliseconds: login.retryAfterMs.clamp(500, 5000)));
  }
  await login.verifyCode('123456');
  _check(login.existing && login.existingTicket != null, 'tài khoản đã có phải trả ticket cho luồng khôi phục');

  // 4. Recovery key sai bị từ chối (ticket vẫn dùng được); đúng thì khôi phục.
  final svc2 = BackupService(api: api2);
  var rejected = false;
  try {
    await svc2.restore(
      ticket: login.existingTicket!, accountId: login.existingAccountId!, recoveryKey: Uint8List.fromList(List.filled(32, 7)),
      openCore: openChatCore, platform: Platform.PLATFORM_UNSPECIFIED,
    );
  } on BackupException {
    rejected = true;
  }
  _check(rejected, 'recovery key sai phải bị từ chối');
  final s2 = await svc2.restore(
    ticket: login.existingTicket!, accountId: login.existingAccountId!, recoveryKey: BackupService.parseKey(shown),
    openCore: openChatCore, platform: Platform.PLATFORM_UNSPECIFIED, store: store2,
  );
  _check(s2.accountId.join(',') == oldAccount.join(',') && s2.deviceId.join(',') != oldDevice.join(','), 'cùng tài khoản, thiết bị mới');

  // 5. Lịch sử còn; vào lại hai hội thoại bằng External Commit.
  final restored = TestUser(api2, store2, s2, alice.phone, serverUrl);
  await restored.startEngine();
  _check(restored.engine.conversations.isEmpty, 'chưa vào hội thoại nào trước khi External Commit');
  _check(await restored.engine.joinAllConversations() == 2, 'phải vào lại 2 hội thoại');
  final rdm = restored.engine.conversations.firstWhere((c) => !c.isGroup);
  final rgrp = restored.engine.conversations.firstWhere((c) => c.isGroup);
  _check(rdm.hexId == dm.hexId && rgrp.hexId == grp.hexId, 'cùng conv_id');
  _check(restored.msgs(rdm).any((m) => m.text == 'lịch sử trước khi mất máy'), 'lịch sử 1-1 còn');
  _check(restored.msgs(rgrp).any((m) => m.text == 'nhóm: lịch sử cũ'), 'lịch sử nhóm còn');

  // 6. Thu hồi thiết bị đã mất: bị gỡ khỏi cả hai nhóm; khóa danh tính cũ ký được statement.
  final devices = await restored.engine.listDevices();
  _check(devices.length == 2, 'ListDevices: máy cũ + máy khôi phục');
  _check(await restored.engine.revokeDevice(oldDevice) == 2, 'gỡ máy cũ khỏi 2 hội thoại');

  // 7. Nói chuyện tiếp.
  await bob.engine.sendText(bobDm.hexId, 'chào mừng trở lại');
  await _waitFor('máy khôi phục nhận tin 1-1', () => restored.msgs(rdm).any((m) => m.text == 'chào mừng trở lại'));
  await restored.engine.sendText(rgrp.hexId, 'mình đã khôi phục');
  await _waitFor('Bob nhận tin nhóm', () => bob.msgs(bobGrp).any((m) => m.text == 'mình đã khôi phục'));

  for (final u in [bob, restored]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}
