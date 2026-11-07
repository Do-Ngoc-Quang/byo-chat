// Thu hồi thiết bị (giao-thuc.md 6.6) với server THẬT: Alice có thiết bị thứ hai (A3) trong 1-1 và nhóm với Bob;
// A1 thu hồi A3 -> A3 bị chặn ở server, bị gỡ khỏi cả hai nhóm, không đọc được tin mới; Bob và A1 vẫn nói chuyện.
import 'dart:async';

import 'package:byo_chat/auth/link_controller.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:byo_chat/storage/session_store.dart';

import 'chat_e2e.dart';

void _check(bool ok, String msg) {
  if (!ok) throw StateError('revoke e2e sai: $msg');
}

Future<void> _waitFor(String what, bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('revoke e2e quá hạn khi chờ: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> runRevokeE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'ralice.');
  final bob = await signUpForTest(serverUrl, 'rbob.');
  await alice.startEngine();
  await bob.startEngine();
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final dm = await alice.engine.openDirect(sms, bob.phone);
  final grp = await alice.engine.createGroup('Nhóm thu hồi', [(sms, bob.phone)]);
  await _waitFor('Bob vào hai hội thoại', () => bob.engine.conversations.length == 2);

  final api3 = ChatApi(ConnectClient(serverUrl));
  final store3 = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore(), namespace: 'ralice3.');
  final link = LinkController(api: api3, openCore: openChatCore, store: store3);
  final offer = await link.start();
  final done = link.complete();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await alice.engine.approveLink(offer);
  final s3 = (await done)!;
  final a3 = TestUser(api3, store3, s3, alice.phone, serverUrl);
  await a3.startEngine();
  _check(await a3.engine.joinAllConversations() == 2, 'A3 vào 2 hội thoại');
  final devices = await alice.engine.listDevices();
  _check(devices.length == 2 && devices.every((d) => !d.revoked), 'ListDevices: 2 thiết bị còn hiệu lực');

  var self = false;
  try {
    await alice.engine.revokeDevice(alice.session.deviceId);
  } on ChatException {
    self = true;
  }
  _check(self, 'không được tự thu hồi');
  final removedFrom = await alice.engine.revokeDevice(s3.deviceId);
  _check(removedFrom == 2, 'A3 phải bị gỡ khỏi 2 nhóm, gỡ $removedFrom');
  _check((await alice.engine.listDevices()).where((d) => d.revoked).length == 1, 'một thiết bị bị thu hồi');

  var blocked = false;
  try {
    await api3.listDevices();
  } on ConnectException {
    blocked = true;
  }
  _check(blocked, 'access token của A3 phải bị vô hiệu ngay');

  final bobDm = bob.engine.conversations.firstWhere((c) => !c.isGroup);
  final bobGrp = bob.engine.conversations.firstWhere((c) => c.isGroup);
  await bob.engine.sendText(bobDm.hexId, 'sau khi thu hồi A3');
  await _waitFor('A1 nhận tin', () => alice.msgs(dm).any((m) => m.text == 'sau khi thu hồi A3'));
  await alice.engine.sendText(grp.hexId, 'nhóm sau thu hồi');
  await _waitFor('Bob nhận tin nhóm', () => bob.msgs(bobGrp).any((m) => m.text == 'nhóm sau thu hồi'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final dm3 = a3.engine.conversations.firstWhere((c) => !c.isGroup);
  _check(!a3.msgs(dm3).any((m) => m.text == 'sau khi thu hồi A3'), 'A3 không được đọc tin sau thu hồi');

  for (final u in [alice, bob, a3]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}
