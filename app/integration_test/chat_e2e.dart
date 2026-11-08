// Chat 1-1 đầu-cuối với server THẬT, lõi THẬT, hai thiết bị (Alice, Bob): đăng nhập, tạo hội thoại,
// Welcome, gửi/nhận qua WebSocket, tắt/mở lại, tin tới khi đang tắt, lấp khoảng trống bằng FetchLog.
// Chạy trên VM, Android, Web (không phụ thuộc flutter_test).
import 'dart:async';
import 'dart:math';

import 'package:byo_chat/auth/link_controller.dart';
import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/chat/chat_engine.dart';
import 'package:byo_chat/chat/local_doc.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart' show Role;
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

class TestUser {
  TestUser(this.api, this.store, this.session, this.phone, this.serverUrl);
  final ChatApi api;
  final SessionStore store;
  Session session;
  final String phone;
  final Uri serverUrl;
  late ChatEngine engine;

  Future<void> startEngine() async {
    engine = ChatEngine(session: session, api: api, store: store, apiBase: serverUrl, backoffBase: const Duration(milliseconds: 100));
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

Future<TestUser> signUpForTest(Uri url, String ns) async {
  final api = ChatApi(ConnectClient(url));
  final store = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore(), namespace: ns);
  final phone = '+8490${1000000 + Random().nextInt(8999999)}';
  final login = LoginController(api: api, openCore: openChatCore, store: store);
  await login.requestOtp(OtpChannel.OTP_CHANNEL_SMS, phone);
  await login.verifyCode('123456');
  _check(login.step == LoginStep.done, 'đăng nhập $ns: ${login.error}');
  return TestUser(api, store, login.session!, phone, url);
}

Future<void> runChatE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'alice.');
  final bob = await signUpForTest(serverUrl, 'bob.');
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
  alice.engine = ChatEngine(
    session: alice.session,
    api: alice.api,
    store: alice.store,
    apiBase: serverUrl,
    backoffBase: const Duration(milliseconds: 100),
  );
  await alice.engine.start(); // chưa chờ online: gửi ngay khi gateway chưa sẵn sàng
  final convA3 = alice.engine.conversations.single;
  await alice.engine.sendText(convA3.hexId, 'gửi khi vừa mở app');
  await _waitFor('Bob nhận tin Alice gửi lúc vừa mở app', () => bob.msgs(convB2).where((m) => m.text == 'gửi khi vừa mở app').length == 1);
  await _waitFor(
    'tin đó được đánh dấu đã gửi',
    () => alice.msgs(convA3).where((m) => m.text == 'gửi khi vừa mở app').every((m) => m.state == MsgState.sent),
  );

  await alice.engine.stop();
  await bob.engine.stop();
  await alice.session.core.dispose();
  await bob.session.core.dispose();
}

/// Nhóm 3 người với server thật (spec 6.2 nhóm, 6.3, 6.4): tạo, thêm, gỡ, quyền, tin trong nhóm.
Future<void> runGroupE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'galice.');
  final bob = await signUpForTest(serverUrl, 'gbob.');
  final carol = await signUpForTest(serverUrl, 'gcarol.');
  for (final u in [alice, bob, carol]) {
    await u.startEngine();
  }
  const sms = OtpChannel.OTP_CHANNEL_SMS;

  // 1. Alice tạo nhóm với Bob; Bob nhận Welcome và biết đó là nhóm, mình không phải admin.
  final g = await alice.engine.createGroup('Nhóm thử', [(sms, bob.phone)]);
  await _waitFor('Bob vào nhóm', () => bob.engine.conversations.length == 1);
  final gb = bob.engine.conversations.single;
  _check(gb.isGroup && !gb.admin && g.isGroup && g.admin, 'cờ nhóm/admin');
  await alice.engine.sendText(g.hexId, 'chào cả nhóm');
  await _waitFor('Bob nhận tin nhóm', () => bob.msgs(gb).any((m) => m.text == 'chào cả nhóm'));

  // 2. Bob (MEMBER) không được thêm người; Alice thêm Carol.
  var denied = false;
  try {
    await bob.engine.addMember(gb.hexId, sms, carol.phone);
  } on ChatException {
    denied = true;
  }
  _check(denied, 'MEMBER không được thêm thành viên');
  await alice.engine.addMember(g.hexId, sms, carol.phone);
  await _waitFor('Carol vào nhóm', () => carol.engine.conversations.length == 1);
  final gc = carol.engine.conversations.single;
  await _waitFor('Bob áp dụng Commit thêm Carol', () => gb.lastSeq == g.lastSeq);
  _check((await bob.engine.memberAccounts(gb.hexId)).length == 3, 'Bob phải thấy 3 thành viên');
  // Carol không đọc được tin trước khi vào (không có khóa epoch cũ), nhưng đọc được tin sau.
  _check(carol.msgs(gc).isEmpty, 'Carol không thấy tin cũ');
  await bob.engine.sendText(gb.hexId, 'Carol có đọc được không');
  await _waitFor(
    'Carol và Alice nhận tin của Bob',
    () => carol.msgs(gc).any((m) => m.text == 'Carol có đọc được không') && alice.msgs(g).any((m) => m.text == 'Carol có đọc được không'),
  );

  // Tên người gửi trong nhóm: Carol thấy tài khoản của Bob (chỉ biết mã rút gọn), Alice thấy số điện thoại đã nhập.
  final fromBob = carol.msgs(gc).firstWhere((m) => m.text == 'Carol có đọc được không');
  _check(fromBob.sender == hex(bob.session.accountId), 'người gửi tin nhóm phải là tài khoản của Bob');
  _check(carol.engine.displayName(fromBob.sender!).startsWith('Tài khoản '), 'Carol chưa biết tên Bob');
  _check(alice.engine.displayName(hex(bob.session.accountId)) == bob.phone, 'Alice thấy số điện thoại đã nhập');
  _check(alice.msgs(g).where((m) => m.mine).every((m) => m.sender == null), 'tin của mình không có người gửi');

  // 3. Alice gỡ Carol; Carol nhận Commit cuối rồi bị đánh dấu đã gỡ và không gửi được nữa.
  await alice.engine.removeMember(g.hexId, carol.session.accountId);
  await _waitFor('Carol biết mình bị gỡ', () => gc.removed);
  await _waitFor('Bob áp dụng Commit gỡ Carol', () => gb.lastSeq == g.lastSeq);
  _check((await alice.engine.memberAccounts(g.hexId)).length == 2, 'còn 2 thành viên');
  await alice.engine.sendText(g.hexId, 'chỉ còn hai người');
  await _waitFor('Bob nhận tin sau khi gỡ Carol', () => bob.msgs(gb).any((m) => m.text == 'chỉ còn hai người'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  _check(!carol.msgs(gc).any((m) => m.text == 'chỉ còn hai người'), 'Carol không được đọc tin sau khi bị gỡ');
  var sendDenied = false;
  try {
    await carol.engine.sendText(gc.hexId, 'còn gửi được không');
  } on ChatException {
    sendDenied = true;
  }
  _check(sendDenied, 'Carol đã bị gỡ không được gửi');

  for (final u in [alice, bob, carol]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}

/// Liên kết thiết bị (giao-thuc.md 6.5) với server thật: Alice có 1-1 với Bob và một nhóm; thiết bị thứ hai của
/// Alice (A3) liên kết, tự vào cả hai bằng External Commit, rồi nhận/gửi tin hai chiều với Bob và A1.
Future<void> runLinkE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'lalice.');
  final bob = await signUpForTest(serverUrl, 'lbob.');
  await alice.startEngine();
  await bob.startEngine();
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final dm = await alice.engine.openDirect(sms, bob.phone);
  final grp = await alice.engine.createGroup('Nhóm liên kết', [(sms, bob.phone)]);
  await _waitFor('Bob vào cả hai hội thoại', () => bob.engine.conversations.length == 2);
  await alice.engine.sendText(dm.hexId, 'tin cũ trước khi liên kết');

  // A3 xin liên kết; A1 duyệt bằng mã đã hiển thị (qua chuỗi mã QR).
  final api3 = ChatApi(ConnectClient(serverUrl));
  final store3 = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore(), namespace: 'lalice3.');
  final link = LinkController(api: api3, openCore: openChatCore, store: store3);
  final offer = LinkOffer.decode((await link.start()).encode());
  _check(offer.shortCode.length == 6, 'mã 6 số');
  final done = link.complete(); // chờ duyệt (long-poll phía server)
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await alice.engine.approveLink(offer);
  final s3 = await done;
  _check(s3 != null, 'liên kết thất bại: ${link.error}');
  _check(hex(s3!.accountId) == hex(alice.session.accountId), 'A3 phải cùng tài khoản với A1');
  _check(hex(s3.deviceId) != hex(alice.session.deviceId), 'A3 là thiết bị khác');

  // A3 vào mọi hội thoại bằng External Commit; A1 và Bob áp dụng Commit đó.
  final a3 = TestUser(api3, store3, s3, alice.phone, serverUrl);
  await a3.startEngine();
  final joined = await a3.engine.joinAllConversations();
  _check(joined == 2 && a3.engine.conversations.length == 2, 'A3 phải vào 2 hội thoại, vào $joined');
  _check(a3.engine.conversations.where((c) => c.isGroup).length == 1, 'một nhóm, một 1-1');
  final dm3 = a3.engine.conversations.firstWhere((c) => !c.isGroup);
  final grp3 = a3.engine.conversations.firstWhere((c) => c.isGroup);
  _check(dm3.hexId == dm.hexId && grp3.hexId == grp.hexId, 'cùng conv_id với A1');
  _check(a3.msgs(dm3).isEmpty, 'A3 không đọc được tin trước khi vào');
  _check((await a3.engine.memberAccounts(grp3.hexId)).length == 2, 'nhóm vẫn 2 tài khoản (3 thiết bị)');

  // Bob gửi vào 1-1 và nhóm: cả A1 và A3 đọc được (MLS đã có thêm thiết bị).
  await bob.engine.sendText(dm.hexId, 'gửi cho cả hai máy của Alice');
  await bob.engine.sendText(grp.hexId, 'nhóm: gửi cho cả hai máy');
  await _waitFor(
    'A1 và A3 nhận tin 1-1',
    () =>
        alice.msgs(dm).any((m) => m.text == 'gửi cho cả hai máy của Alice') &&
        a3.msgs(dm3).any((m) => m.text == 'gửi cho cả hai máy của Alice'),
  );
  await _waitFor(
    'A1 và A3 nhận tin nhóm',
    () =>
        alice.msgs(grp).any((m) => m.text == 'nhóm: gửi cho cả hai máy') && a3.msgs(grp3).any((m) => m.text == 'nhóm: gửi cho cả hai máy'),
  );

  // A3 gửi: Bob và A1 đọc được.
  await a3.engine.sendText(dm3.hexId, 'từ máy thứ hai');
  await _waitFor(
    'Bob và A1 nhận tin của A3',
    () =>
        bob.msgs(bob.engine.conversations.firstWhere((c) => !c.isGroup)).any((m) => m.text == 'từ máy thứ hai') &&
        alice.msgs(dm).any((m) => m.text == 'từ máy thứ hai'),
  );

  // Chạy lại joinAllConversations là no-op.
  _check(await a3.engine.joinAllConversations() == 0, 'chạy lại không vào thêm');

  for (final u in [alice, bob, a3]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}

/// Rời nhóm (giao-thuc.md 6.4) với server thật: Alice (OWNER, online) tạo nhóm với Bob và Carol; chủ nhóm không rời
/// được; Bob xin rời -> Alice tự commit gỡ Bob; Bob bị đánh dấu đã rời, không gửi được; Alice và Carol nói chuyện tiếp.
Future<void> runLeaveE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'lvalice.');
  final bob = await signUpForTest(serverUrl, 'lvbob.');
  final carol = await signUpForTest(serverUrl, 'lvcarol.');
  for (final u in [alice, bob, carol]) {
    await u.startEngine();
  }
  alice.engine.autoCommitDelayMs = 50;
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final g = await alice.engine.createGroup('Nhóm rời', [(sms, bob.phone), (sms, carol.phone)]);
  await _waitFor('Bob và Carol vào nhóm', () => bob.engine.conversations.length == 1 && carol.engine.conversations.length == 1);
  final gb = bob.engine.conversations.single;
  final gc = carol.engine.conversations.single;
  _check(g.owner && !gb.owner, 'Alice là chủ nhóm, Bob thì không');

  var ownerBlocked = false;
  try {
    await alice.engine.leaveGroup(g.hexId);
  } on ChatException {
    ownerBlocked = true;
  }
  _check(ownerBlocked, 'chủ nhóm không được rời');

  // Bob xin rời; trong lúc chờ vẫn nhận tin; rồi Alice tự commit gỡ Bob.
  await bob.engine.leaveGroup(gb.hexId);
  _check(gb.leaving, 'Bob phải ở trạng thái đang rời');
  await _waitFor('Bob bị gỡ khỏi nhóm', () => gb.removed);
  _check(!gb.leaving, 'hết trạng thái đang rời');
  await _waitFor('Alice áp dụng Commit gỡ Bob', () => alice.engine.doc.convs[g.hexId]!.lastSeq >= gb.lastSeq);
  _check((await alice.engine.memberAccounts(g.hexId)).length == 2, 'nhóm còn 2 người');
  await _waitFor('Carol thấy nhóm còn 2 người', () => gc.lastSeq == g.lastSeq);
  _check((await carol.engine.memberAccounts(gc.hexId)).length == 2, 'Carol thấy 2 người');

  // Alice và Carol nói chuyện tiếp; Bob không đọc được và không gửi được.
  await alice.engine.sendText(g.hexId, 'Bob đã rời, hai người còn lại');
  await _waitFor('Carol nhận tin', () => carol.msgs(gc).any((m) => m.text == 'Bob đã rời, hai người còn lại'));
  await carol.engine.sendText(gc.hexId, 'Carol trả lời');
  await _waitFor('Alice nhận trả lời', () => alice.msgs(g).any((m) => m.text == 'Carol trả lời'));
  await Future<void>.delayed(const Duration(milliseconds: 400));
  _check(!bob.msgs(gb).any((m) => m.text == 'Bob đã rời, hai người còn lại'), 'Bob không được đọc tin sau khi rời');
  var sendBlocked = false;
  try {
    await bob.engine.sendText(gb.hexId, 'còn gửi được không');
  } on ChatException {
    sendBlocked = true;
  }
  _check(sendBlocked, 'Bob đã rời không được gửi');

  for (final u in [alice, bob, carol]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}

/// Đổi vai trò và chuyển quyền chủ nhóm (spec 6.3): Bob lên ADMIN rồi nhận quyền chủ; chủ cũ rời được.
Future<void> runRoleE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'rlalice.');
  final bob = await signUpForTest(serverUrl, 'rlbob.');
  final carol = await signUpForTest(serverUrl, 'rlcarol.');
  for (final u in [alice, bob, carol]) {
    await u.startEngine();
  }
  alice.engine.autoCommitDelayMs = 50;
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final g = await alice.engine.createGroup('Nhóm vai trò', [(sms, bob.phone), (sms, carol.phone)]);
  await _waitFor('Bob và Carol vào nhóm', () => bob.engine.conversations.length == 1 && carol.engine.conversations.length == 1);
  final gb = bob.engine.conversations.single;
  final gc = carol.engine.conversations.single;
  final bobId = bob.session.accountId;
  _check(gb.title == 'Nhóm vai trò' && gc.title == 'Nhóm vai trò', 'người nhận Welcome đọc tên nhóm từ chat_policy: ${gb.title}');

  var denied = false;
  try {
    await bob.engine.changeRole(gb.hexId, carol.session.accountId, Role.ROLE_ADMIN); // Bob chưa là ADMIN
  } on ChatException {
    denied = true;
  }
  _check(denied, 'MEMBER không đổi được vai trò');

  await alice.engine.changeRole(g.hexId, bobId, Role.ROLE_ADMIN);
  await _waitFor('Bob thành ADMIN', () => gb.admin && !gb.owner);
  _check(!gc.admin, 'Carol vẫn là MEMBER');
  var ownerDenied = false;
  try {
    await bob.engine.changeRole(gb.hexId, carol.session.accountId, Role.ROLE_OWNER);
  } on ChatException {
    ownerDenied = true;
  }
  _check(ownerDenied, 'ADMIN không trao được OWNER');

  await alice.engine.transferOwnership(g.hexId, bobId);
  _check(!g.owner && g.admin, 'Alice xuống ADMIN');
  await _waitFor('Bob thành OWNER', () => gb.owner);

  // Alice không còn là chủ nên rời được; Bob (chủ mới) tự commit gỡ Alice.
  bob.engine.autoCommitDelayMs = 50;
  await alice.engine.leaveGroup(g.hexId);
  await _waitFor('Alice bị gỡ khỏi nhóm', () => g.removed);
  await bob.engine.sendText(gb.hexId, 'chủ mới');
  await _waitFor('Carol nhận tin', () => carol.msgs(gc).any((m) => m.text == 'chủ mới'));

  for (final u in [alice, bob, carol]) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}

/// Tranh chấp epoch (spec 6.3): hai ADMIN cùng lúc gỡ hai người khác nhau; một bên nhận EPOCH_MISMATCH, đồng bộ rồi dựng lại.
Future<void> runEpochRaceE2E(Uri serverUrl) async {
  final alice = await signUpForTest(serverUrl, 'eralice.');
  final bob = await signUpForTest(serverUrl, 'erbob.');
  final carol = await signUpForTest(serverUrl, 'ercarol.');
  final dave = await signUpForTest(serverUrl, 'erdave.');
  final all = [alice, bob, carol, dave];
  for (final u in all) {
    await u.startEngine();
  }
  const sms = OtpChannel.OTP_CHANNEL_SMS;
  final g = await alice.engine.createGroup('Nhóm đua epoch', [(sms, bob.phone), (sms, carol.phone), (sms, dave.phone)]);
  await _waitFor('cả ba vào nhóm', () => all.skip(1).every((u) => u.engine.conversations.length == 1));
  final gb = bob.engine.conversations.single;
  await alice.engine.changeRole(g.hexId, bob.session.accountId, Role.ROLE_ADMIN);
  await _waitFor('Bob thành ADMIN', () => gb.admin);

  await Future.wait([
    alice.engine.removeMember(g.hexId, carol.session.accountId),
    bob.engine.removeMember(gb.hexId, dave.session.accountId),
  ]);
  final gc = carol.engine.conversations.single;
  final gd = dave.engine.conversations.single;
  await _waitFor('Carol và Dave bị gỡ', () => gc.removed && gd.removed);
  await _waitFor('hai ADMIN cùng epoch', () => g.lastSeq == gb.lastSeq);
  _check((await alice.engine.memberAccounts(g.hexId)).length == 2, 'Alice thấy 2 người');
  _check((await bob.engine.memberAccounts(gb.hexId)).length == 2, 'Bob thấy 2 người');

  await alice.engine.sendText(g.hexId, 'sau đua epoch');
  await _waitFor('Bob đọc được', () => bob.msgs(gb).any((m) => m.text == 'sau đua epoch'));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _check(
    !carol.msgs(gc).any((m) => m.text == 'sau đua epoch') && !dave.msgs(gd).any((m) => m.text == 'sau đua epoch'),
    'người bị gỡ không đọc được',
  );

  for (final u in all) {
    await u.engine.stop();
    await u.session.core.dispose();
  }
}
