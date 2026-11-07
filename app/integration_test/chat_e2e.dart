// Chat 1-1 đầu-cuối với server THẬT, lõi THẬT, hai thiết bị (Alice, Bob): đăng nhập, tạo hội thoại,
// Welcome, gửi/nhận qua WebSocket, tắt/mở lại, tin tới khi đang tắt, lấp khoảng trống bằng FetchLog.
// Chạy trên VM, Android, Web (không phụ thuộc flutter_test).
import 'dart:async';
import 'dart:math';

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:byo_chat/storage/session_store.dart';

void _check(bool ok, String msg) {
  if (!ok) throw StateError('chat e2e sai: $msg');
}

Future<void> _waitFor(String what, bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('chat e2e quá hạn khi chờ: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class _User {
  _User(this.api, this.store, this.session, this.phone, this.serverUrl);
  final ChatApi api;
  final SessionStore store;
  Session session;
  final String phone;
  final Uri serverUrl;
  late ChatEngine engine;

  Future<void> startEngine() async {
    engine = ChatEngine(
      session: session, api: api, store: store, apiBase: serverUrl,
      backoffBase: const Duration(milliseconds: 100),
    );
    await engine.start();
    await engine.whenOnline();
  }

  /// "Tắt app": dừng engine, hủy lõi; "mở lại": khôi phục từ kho đã lưu bằng ChatApi mới.
  Future<void> restart({bool startNow = true}) async {
    await engine.stop();
    await session.core.dispose();
    final s = await store.restore(ChatApi(ConnectClient(serverUrl)), openChatCore);
    if (s == null) throw StateError('chat e2e sai: không khôi phục được phiên của $phone');
    session = s;
    if (startNow) await startEngine();
  }

  Future<void> startEngineAgain() => startEngine();

  List<ChatMessage> msgs(ConvState c) => engine.messages(c.hexId);
}

Future<_User> _signUp(Uri url, String ns) async {
  final api = ChatApi(ConnectClient(url));
  final store = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore(), namespace: ns);
  final phone = '+8490${1000000 + Random().nextInt(8999999)}';
  final login = LoginController(api: api, openCore: openChatCore, store: store);
  await login.requestOtp(OtpChannel.OTP_CHANNEL_SMS, phone);
  await login.verifyCode('123456');
  _check(login.step == LoginStep.done, 'đăng nhập $ns: ${login.error}');
  return _User(api, store, login.session!, phone, url);
}

Future<void> runChatE2E(Uri serverUrl) async {
  final alice = await _signUp(serverUrl, 'alice.');
  final bob = await _signUp(serverUrl, 'bob.');
  await alice.startEngine();
  await bob.startEngine();
  const sms = OtpChannel.OTP_CHANNEL_SMS;

  // 1. Alice mở hội thoại với Bob bằng số điện thoại; Bob nhận Welcome qua WebSocket.
  final convA = await alice.engine.openDirect(sms, bob.phone);
  await _waitFor('Bob nhận Welcome', () => bob.engine.conversations.length == 1);
  final convB = bob.engine.conversations.single;
  _check(convA.hexId == convB.hexId, 'hai bên phải cùng conv_id');
  _check(bob.engine.conversations.single.peerAccount != null, 'Bob phải biết người kia là ai (từ credential trong nhóm)');

  // 2. Trao đổi tin hai chiều (nhiều tin liên tiếp để kiểm thứ tự).
  for (final t in ['xin chào Bob', 'tin thứ hai', 'tin thứ ba']) {
    await alice.engine.sendText(convA.hexId, t);
  }
  await _waitFor('Bob nhận 3 tin', () => bob.msgs(convB).length == 3);
  _check(bob.msgs(convB).map((m) => m.text).join('|') == 'xin chào Bob|tin thứ hai|tin thứ ba', 'thứ tự/nội dung tin');
  _check(alice.msgs(convA).every((m) => m.state == MsgState.sent && m.seq > 1), 'tin của Alice phải ở trạng thái đã gửi có seq');
  await bob.engine.sendText(convB.hexId, 'chào Alice');
  await _waitFor('Alice nhận trả lời', () => alice.msgs(convA).any((m) => m.text == 'chào Alice'));

  // 3. Bob bấm mở hội thoại với Alice: dùng hội thoại sẵn có, không tạo trùng.
  final again = await bob.engine.openDirect(sms, alice.phone);
  _check(again.hexId == convB.hexId && bob.engine.conversations.length == 1, 'không được tạo hội thoại trùng');

  // 4. Bob "tắt app"; Alice gửi tin trong lúc Bob offline; Bob mở lại nhận được đúng một lần.
  await bob.restart(startNow: false);
  await alice.engine.sendText(convA.hexId, 'gửi khi bạn offline');
  await bob.startEngineAgain();
  await _waitFor('Bob nhận tin tồn đọng', () => bob.msgs(bob.engine.conversations.single).any((m) => m.text == 'gửi khi bạn offline'));
  final convB2 = bob.engine.conversations.single;
  _check(bob.msgs(convB2).where((m) => m.text == 'gửi khi bạn offline').length == 1, 'tin tồn đọng bị trùng');
  _check(bob.msgs(convB2).any((m) => m.text == 'xin chào Bob'), 'lịch sử trước khi tắt app phải còn');

  // 5. Sau khi khôi phục, Bob gửi tin (ratchet khôi phục đúng) và Alice đọc được; ngược lại cũng vậy.
  await bob.engine.sendText(convB2.hexId, 'mình đã quay lại');
  await _waitFor('Alice nhận tin sau khi Bob mở lại', () => alice.msgs(convA).any((m) => m.text == 'mình đã quay lại'));
  await alice.engine.sendText(convA.hexId, 'chào mừng trở lại');
  await _waitFor('Bob nhận tin sau khi mở lại', () => bob.msgs(convB2).any((m) => m.text == 'chào mừng trở lại'));

  // 6. Khoảng trống seq: ép Bob "quên" 2 mục gần nhất, rồi Alice gửi tin mới; Bob phải lấy FetchLog và theo kịp.
  final head = convB2.lastSeq;
  convB2.lastSeq = head - 2;
  convB2.skip.clear();
  await alice.engine.sendText(convA.hexId, 'sau khoảng trống');
  await _waitFor('Bob theo kịp sau khoảng trống', () => bob.msgs(convB2).any((m) => m.text == 'sau khoảng trống'));
  _check(convB2.lastSeq == head + 1, 'lastSeq phải bằng ${head + 1}, có ${convB2.lastSeq}');

  // 7. Tin chờ gửi khi offline được gửi khi kết nối lại (cùng client_msg_id, không trùng).
  await alice.engine.stop();
  await alice.session.core.dispose();
  final s = await alice.store.restore(ChatApi(ConnectClient(serverUrl)), openChatCore);
  alice.session = s!;
  alice.engine = ChatEngine(session: alice.session, api: alice.api, store: alice.store, apiBase: serverUrl, backoffBase: const Duration(milliseconds: 100));
  await alice.engine.start(); // chưa chờ online: gửi ngay khi gateway chưa sẵn sàng
  final convA3 = alice.engine.conversations.single;
  await alice.engine.sendText(convA3.hexId, 'gửi khi vừa mở app');
  await _waitFor('Bob nhận tin Alice gửi lúc vừa mở app', () => bob.msgs(convB2).where((m) => m.text == 'gửi khi vừa mở app').length == 1);
  await _waitFor('tin đó được đánh dấu đã gửi', () => alice.msgs(convA3).where((m) => m.text == 'gửi khi vừa mở app').every((m) => m.state == MsgState.sent));

  await alice.engine.stop();
  await bob.engine.stop();
  await alice.session.core.dispose();
  await bob.session.core.dispose();
}
