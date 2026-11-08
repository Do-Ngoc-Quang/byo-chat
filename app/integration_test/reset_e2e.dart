// Khôi phục KHÔNG có bản sao lưu (giao-thuc.md 6.14) với server THẬT: Alice mất hết thiết bị, đăng nhập lại bằng OTP,
// đặt khóa danh tính mới (`reset_identity`), vào lại 1-1 và nhóm bằng External Commit, gỡ lá cũ của chính mình; lịch sử
// mất; Bob chấp nhận khóa mới ngay (không cảnh báo) và hai bên nói chuyện tiếp; thiết bị cũ bị thu hồi ở server.
import 'dart:async';

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:byo_chat/storage/session_store.dart';

import 'chat_e2e.dart';

void _check(bool ok, String msg) {
  if (!ok) throw StateError('reset e2e sai: $msg');
}

Future<void> _waitFor(String what, bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('reset e2e quá hạn khi chờ: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> runResetIdentityE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'rialice.');
  final bob = await signUpForTest(serverUrl, 'ribob.');
  await alice.startEngine();
  await bob.startEngine();
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final dm = await alice.engine.openDirect(sms, bob.phone);
  final grp = await alice.engine.createGroup('Nhóm reset', [(sms, bob.phone)]);
  await _waitFor('Bob vào hai hội thoại', () => bob.engine.conversations.length == 2);
  final bobDm = bob.engine.conversations.firstWhere((c) => !c.isGroup);
  final bobGrp = bob.engine.conversations.firstWhere((c) => c.isGroup);
  await alice.engine.sendText(dm.hexId, 'tin trước khi mất máy');
  await _waitFor('Bob nhận tin cũ', () => bob.msgs(bobDm).any((m) => m.text == 'tin trước khi mất máy'));
  final oldDevice = alice.session.deviceId;
  final oldAccount = alice.session.accountId;

  // Mất hết thiết bị, không có sao lưu.
  await alice.engine.stop();
  await alice.session.core.dispose();
  await alice.store.clear();

  final api2 = ChatApi(ConnectClient(serverUrl));
  final store2 = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore(), namespace: 'rialice2.');
  final login = LoginController(api: api2, openCore: openChatCore, store: store2);
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (true) {
    await login.requestOtp(sms, alice.phone);
    if (login.step == LoginStep.code) break;
    _check(DateTime.now().isBefore(end) && login.retryAfterMs > 0, 'xin OTP lần hai: ${login.error}');
    await Future<void>.delayed(Duration(milliseconds: login.retryAfterMs.clamp(500, 5000)));
  }
  await login.verifyCode('123456');
  _check(login.existing, 'tài khoản đã có');
  await login.resetIdentity();
  final s2 = login.session;
  _check(s2 != null && login.needsJoin, 'reset_identity phải cho phiên mới và báo cần vào lại hội thoại: ${login.error}');
  _check(s2!.accountId.join(',') == oldAccount.join(',') && s2.deviceId.join(',') != oldDevice.join(','), 'cùng tài khoản, thiết bị mới');

  final fresh = TestUser(api2, store2, s2, alice.phone, serverUrl);
  await fresh.startEngine();
  _check(await fresh.engine.joinAllConversations() == 2, 'vào lại 2 hội thoại bằng External Commit');
  _check(await fresh.engine.removeStaleLeaves() == 2, 'gỡ lá cũ khỏi 2 hội thoại');
  final rdm = fresh.engine.conversations.firstWhere((c) => !c.isGroup);
  final rgrp = fresh.engine.conversations.firstWhere((c) => c.isGroup);
  _check(rdm.hexId == dm.hexId && rgrp.hexId == grp.hexId, 'cùng conv_id');
  _check(!fresh.msgs(rdm).any((m) => m.text == 'tin trước khi mất máy'), 'tin cũ phải mất (không có sao lưu)');

  // Thiết bị cũ bị thu hồi ở server; chỉ còn thiết bị mới hiệu lực.
  final devs = await fresh.engine.listDevices();
  _check(devs.length == 2 && devs.where((d) => !d.revoked).length == 1, 'máy cũ bị thu hồi, máy mới còn hiệu lực');

  // Bob áp dụng Commit gỡ lá cũ (chấp nhận khóa mới) và hai bên nói chuyện tiếp.
  await _waitFor('Bob áp dụng hết Commit', () => bobDm.lastSeq >= rdm.lastSeq && bobGrp.lastSeq >= rgrp.lastSeq);
  await bob.engine.sendText(bobDm.hexId, 'chào mừng trở lại');
  await _waitFor('Alice mới nhận tin 1-1', () => fresh.msgs(rdm).any((m) => m.text == 'chào mừng trở lại'));
  await fresh.engine.sendText(rgrp.hexId, 'mình đã bắt đầu lại');
  await _waitFor('Bob nhận tin nhóm', () => bob.msgs(bobGrp).any((m) => m.text == 'mình đã bắt đầu lại'));
  _check((await bob.engine.memberAccounts(bobGrp.hexId)).length == 2, 'nhóm vẫn 2 tài khoản');

  for (final u in [bob, fresh]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}
