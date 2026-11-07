// Kịch bản MLS qua cầu nối, dùng chung cho test VM (FFI), Android và Web.
import 'dart:convert';
import 'dart:typed_data';

import 'package:byo_chat/core/chatcore.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// 1-1 qua Welcome, thiết bị thứ ba vào bằng External Commit, SFrame khớp, lỗi được báo.
Future<void> runMlsScenario(Future<ChatCore> Function() open) async {
  final a = await open(), b = await open(), c = await open();
  try {
    await a.open(_b('alice-1'));
    await b.open(_b('bob-1'));
    await c.open(_b('carol-1'));
    final conv = _b('group-1');

    await a.createGroup(conv);
    final out = await a.addMembers(conv, [await b.keyPackage()]);
    await b.joinWelcome(conv, out.welcome);
    _check(await a.epoch(conv) == await b.epoch(conv), 'epoch lệch');

    final ct = await a.encrypt(conv, _b('xin chào'));
    _eq(utf8.decode(await b.decrypt(conv, ct)), 'xin chào');

    final commit = await c.externalJoin(conv, await a.groupInfo(conv));
    await a.applyCommit(conv, commit);
    await b.applyCommit(conv, commit);
    final ct2 = await c.encrypt(conv, _b('ba người'));
    _eq(utf8.decode(await a.decrypt(conv, ct2)), 'ba người');
    _eq(utf8.decode(await b.decrypt(conv, ct2)), 'ba người');

    final ka = await a.sframeKey(conv, _b('call-1'));
    _check(_same(ka, await c.sframeKey(conv, _b('call-1'))), 'SFrame lệch');
    _eq(ka.length, 32);

    var threw = false;
    try {
      await a.epoch(_b('khong-co'));
    } on ChatCoreException {
      threw = true;
    }
    _check(threw, 'lỗi của lõi không được ném');
  } finally {
    await a.dispose();
    await b.dispose();
    await c.dispose();
  }
}

void _check(bool ok, String msg) {
  if (!ok) throw StateError('kịch bản MLS sai: $msg');
}

void _eq(Object? a, Object? b) => _check(a == b, '$a != $b');

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _id16(int n) => Uint8List.fromList(List.filled(16, n));

/// Credential theo spec 6.1 qua cầu nối: thiết bị đầu tiên sinh khóa danh tính, thiết bị khôi phục dùng
/// lại khóa đó; KeyPackage hàng loạt; kiểm KeyPackage nhận từ server; nhóm MLS chạy với credential thật.
Future<void> runCredentialScenario(Future<ChatCore> Function() open) async {
  final a = await open(), b = await open(), c = await open();
  try {
    const created = 1700000000000;
    await a.openDevice(accountId: _id16(1), deviceId: _id16(10), createdMs: created);
    final ca = await a.deviceCredential();
    _eq(ca.credential.length, 136);
    _eq(ca.devicePublicKey.length, 32);
    _eq(ca.identityPublicKey.length, 32);
    // 8 byte created_ms big-endian ở vị trí 64..72
    final cd = ByteData.sublistView(ca.credential, 64, 72);
    _eq(cd.getUint32(0) * 0x100000000 + cd.getUint32(4), created);

    // Thiết bị thứ hai (khôi phục từ khóa danh tính đã xuất): cùng khóa công khai, khóa thiết bị khác.
    await b.openDevice(accountId: _id16(1), deviceId: _id16(11), identityKey: await a.identityExport(), createdMs: created);
    final cb = await b.deviceCredential();
    _check(_same(cb.identityPublicKey, ca.identityPublicKey), 'khóa danh tính phải trùng');
    _check(!_same(cb.devicePublicKey, ca.devicePublicKey), 'khóa thiết bị phải khác');

    // KeyPackage hàng loạt như RegisterDevice (100 gói một lần + 1 last resort), đều dưới 4 KiB.
    final kps = await a.keyPackages(100);
    _eq(kps.length, 100);
    _check(kps.every((k) => k.length <= 4096 && k[1] == 1 && k[3] == 5), 'KeyPackage sai tiêu đề/kích thước');
    final last = await a.lastResortKeyPackage();
    _check(last.length <= 4096, 'last resort quá lớn');

    // Kiểm KeyPackage nhận từ server: đúng thì qua, sai tài khoản mong đợi thì lỗi.
    await c.openDevice(accountId: _id16(3), deviceId: _id16(12), createdMs: created);
    await c.verifyKeyPackage(
        keyPackage: kps[0], credential: ca.credential, identityPublicKey: ca.identityPublicKey, expectedAccountId: _id16(1));
    var threw = false;
    try {
      await c.verifyKeyPackage(
          keyPackage: kps[0], credential: ca.credential, identityPublicKey: ca.identityPublicKey, expectedAccountId: _id16(2));
    } on ChatCoreException {
      threw = true;
    }
    _check(threw, 'sai tài khoản phải bị từ chối');

    // Nhóm MLS với credential thật: A thêm C bằng KeyPackage một lần, C thêm B bằng last resort.
    final conv = _b('cred-group');
    await a.createGroup(conv);
    final kc = (await c.keyPackages(1))[0];
    final out = await a.addMembers(conv, [kc]);
    await c.joinWelcome(conv, out.welcome);
    final out2 = await a.addMembers(conv, [await b.lastResortKeyPackage()]);
    await c.applyCommit(conv, out2.commit);
    await b.joinWelcome(conv, out2.welcome);
    final ct = await b.encrypt(conv, _b('xin chào'));
    _eq(utf8.decode(await a.decrypt(conv, ct)), 'xin chào');
    _eq(utf8.decode(await c.decrypt(conv, ct)), 'xin chào');
  } finally {
    await a.dispose();
    await b.dispose();
    await c.dispose();
  }
}
