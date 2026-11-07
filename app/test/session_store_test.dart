import 'dart:convert';
import 'dart:typed_data';

import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/gen/chat/v1/services.pbenum.dart';
import 'package:byo_chat/main.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:byo_chat/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_server.dart';

class Rig {
  final secrets = MemorySecretStore();
  final blobs = MemoryBlobStore();
  late final SessionStore store = SessionStore(secrets: secrets, blobs: blobs);
  final srv = FakeServer();
  final cores = <FakeCore>[];

  Future<FakeCore> open() async {
    final c = FakeCore();
    cores.add(c);
    return c;
  }

  Future<LoginController> loggedIn() async {
    final c = LoginController(api: srv.api, openCore: open, store: store);
    await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+84901234567');
    await c.verifyCode('123456');
    expect(c.step, LoginStep.done, reason: c.error);
    return c;
  }
}

void main() {
  test('đăng nhập ghi bền khóa, snapshot và phiên trước khi báo xong', () async {
    final r = Rig();
    final c = await r.loggedIn();
    expect(r.cores.single.snapshots, 1);
    expect(await r.store.exists(), isTrue);
    expect(await r.blobs.read('core.snapshot'), FakeCore.snapshotBytes);
    // khóa mã hóa snapshot: 32 byte ngẫu nhiên, nằm ở kho bí mật chứ không ở kho blob
    expect(base64.decode((await r.secrets.read('byo.snapshot-key'))!), hasLength(32));
    expect(c.session, isNotNull);
  });

  test('khôi phục sau khi tắt app: cùng thiết bị, lõi nạp lại, token còn dùng được, không gọi refresh', () async {
    final r = Rig();
    final first = (await r.loggedIn()).session!;

    final srv2 = FakeServer(); // "tiến trình mới"
    final api2 = srv2.api;
    final restoredCore = <FakeCore>[];
    final s = await r.store.restore(api2, () async => FakeCore().also(restoredCore.add));
    expect(s, isNotNull);
    expect(s!.accountId, first.accountId);
    expect(s.deviceId, first.deviceId);
    expect(restoredCore.single.restored, isTrue);
    expect(api2.client.accessToken, 'tok');
    expect(srv2.refreshes, 0);
    expect(s.remainingKeyPackages, 100);
  });

  test('access token sắp hết hạn: làm mới, xoay refresh token và ghi lại ngay', () async {
    final r = Rig();
    r.srv.accessTtlMs = 10 * 1000; // còn dưới 1 phút
    await r.loggedIn();

    final srv2 = FakeServer();
    final s = await r.store.restore(srv2.api, () async => FakeCore());
    expect(srv2.refreshes, 1);
    expect(s!.tokens.refreshToken, 'ref2');
    // lần khởi động sau đọc được refresh token mới
    final meta = jsonDecode((await r.secrets.read('byo.session'))!) as Map;
    expect(meta['refresh'], 'ref2');
  });

  test('refresh bị từ chối (thu hồi/vô hiệu): xóa sạch dữ liệu thiết bị', () async {
    final r = Rig();
    r.srv.accessTtlMs = 1000;
    await r.loggedIn();
    final srv2 = FakeServer()..refreshMode = 'revoked';
    final core = FakeCore();
    final api2 = srv2.api;
    expect(await r.store.restore(api2, () async => core), isNull);
    expect(core.disposed, isTrue);
    expect(await r.store.exists(), isFalse);
    expect(await r.blobs.read('core.snapshot'), isNull);
    expect(await r.secrets.read('byo.snapshot-key'), isNull);
    expect(api2.client.accessToken, isNull);
  });

  test('mất mạng khi làm mới: vẫn vào phiên (offline), dữ liệu giữ nguyên', () async {
    final r = Rig();
    r.srv.accessTtlMs = 1000;
    await r.loggedIn();
    final srv2 = FakeServer()..refreshMode = 'down';
    final s = await r.store.restore(srv2.api, () async => FakeCore());
    expect(s, isNotNull);
    expect(await r.store.exists(), isTrue);
  });

  test('snapshot hỏng hoặc thiếu một nửa: không vào phiên nửa vời, dọn sạch', () async {
    var r = Rig();
    await r.loggedIn();
    await r.blobs.write('core.snapshot', Uint8List.fromList([1, 2, 3])); // sai nội dung
    final core = FakeCore();
    expect(await r.store.restore(r.srv.api, () async => core), isNull);
    expect(core.disposed, isTrue);
    expect(await r.store.exists(), isFalse);

    r = Rig();
    await r.loggedIn();
    await r.secrets.delete('byo.snapshot-key'); // mất khóa
    expect(await r.store.restore(r.srv.api, () async => FakeCore()), isNull);
    expect(await r.blobs.read('core.snapshot'), isNull, reason: 'blob mồ côi phải bị xóa');

    r = Rig();
    expect(await r.store.restore(r.srv.api, () async => FakeCore()), isNull, reason: 'chưa lưu gì');
  });

  test('đăng xuất xóa khóa, snapshot và phiên', () async {
    final r = Rig();
    final c = await r.loggedIn();
    await c.logout();
    expect(c.session, isNull);
    expect(await r.store.exists(), isFalse);
    expect(await r.blobs.read('core.snapshot'), isNull);
    expect(await r.secrets.read('byo.snapshot-key'), isNull);
    expect(r.cores.single.disposed, isTrue);
  });

  test('khóa mã hóa giữ nguyên giữa các lần lưu (không sinh lại)', () async {
    final r = Rig();
    final c = await r.loggedIn();
    final k1 = await r.secrets.read('byo.snapshot-key');
    await r.store.save(c.session!);
    expect(await r.secrets.read('byo.snapshot-key'), k1);
  });

  testWidgets('mở app: có phiên lưu thì vào thẳng màn đã đăng nhập, đăng xuất thì về đăng nhập', (tester) async {
    final r = Rig();
    await tester.runAsync(() async => await r.loggedIn());
    final srv2 = FakeServer();
    await tester.pumpWidget(ByoChatApp(api: srv2.api, openCore: () async => FakeCore(), store: r.store, enableChat: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('signed-in')), findsOneWidget);
    expect(srv2.calls, isEmpty, reason: 'không cần gọi mạng khi token còn hạn');

    await tester.tap(find.byKey(const Key('logout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-otp')), findsOneWidget);
    expect(await r.store.exists(), isFalse);
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
