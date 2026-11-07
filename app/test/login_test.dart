import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/auth/uuid7.dart';
import 'package:byo_chat/gen/chat/v1/common.pbenum.dart';
import 'package:byo_chat/gen/chat/v1/services.pbenum.dart';
import 'package:byo_chat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_server.dart';

void main() {
  group('LoginController', () {
    test('đăng nhập OTP rồi đăng ký thiết bị đầu tiên', () async {
      final srv = FakeServer();
      final core = FakeCore();
      final api = srv.api;
      final c = LoginController(api: api, openCore: () async => core, platform: Platform.PLATFORM_ANDROID);

      await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, ' +84901234567 ');
      expect(c.step, LoginStep.code);
      expect(c.retryAfterMs, 30000);

      await c.verifyCode('123456');
      expect(c.error, isNull);
      expect(c.step, LoginStep.done);
      expect(srv.calls, ['RequestOtp', 'VerifyOtp', 'RegisterDevice', 'CountKeyPackages']);

      // RegisterDevice mang đủ thứ spec 6.1 yêu cầu
      final r = srv.registered!;
      expect(r.sessionTicket, List.filled(32, 9));
      expect(r.deviceId.length, 16);
      expect(r.credential.length, 136);
      expect(r.devicePublicKey.length, 32);
      expect(r.accountIdentityPublicKey.length, 32); // thiết bị đầu tiên
      expect(r.keyPackages.length, 100);
      expect(r.lastResortKeyPackage, isNotEmpty);
      expect(r.platform, Platform.PLATFORM_ANDROID);
      // thiết bị mở với đúng tài khoản/thiết bị trong credential
      expect(core.openedWith, isNotNull);

      // token dùng được cho các RPC sau, và phiên có số liệu từ server
      expect(c.session!.remainingKeyPackages, 100);
      expect(c.session!.tokens.accessToken, 'tok');
      expect(api.client.accessToken, 'tok');
    });

    test('đích sai và mã sai hiện lỗi tiếng Việt, không đi tiếp', () async {
      final srv = FakeServer();
      final c = LoginController(api: srv.api, openCore: () async => FakeCore());
      await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '0901234567');
      expect(c.step, LoginStep.contact);
      expect(c.error, contains('không hợp lệ'));

      await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+84901234567');
      await c.verifyCode('000000');
      expect(c.step, LoginStep.code);
      expect(c.error, isNotNull);
      expect(srv.calls, isNot(contains('RegisterDevice')));
    });

    test('RATE_LIMITED báo số giây chờ', () async {
      final srv = FakeServer()..rateLimitMs = 12000;
      final c = LoginController(api: srv.api, openCore: () async => FakeCore());
      await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+84901234567');
      expect(c.error, contains('12 giây'));
      expect(c.retryAfterMs, 12000);
    });

    test('tài khoản đã có: không đăng ký, hướng dẫn liên kết', () async {
      final srv = FakeServer(newAccount: false);
      final c = LoginController(api: srv.api, openCore: () async => FakeCore());
      await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+84901234567');
      await c.verifyCode('123456');
      expect(c.session, isNull);
      expect(c.step, LoginStep.contact);
      expect(c.error, contains('đã có thiết bị khác'));
      expect(srv.calls, isNot(contains('RegisterDevice')));
    });

    test('đăng ký lỗi tạm thời: thử lại được và dọn lõi cũ', () async {
      final srv = FakeServer()..failRegister = 1;
      final cores = <FakeCore>[];
      final c = LoginController(api: srv.api, openCore: () async => FakeCore().also(cores.add));
      await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+84901234567');
      await c.verifyCode('123456');
      expect(c.step, LoginStep.registering);
      expect(c.error, contains('bận'));
      expect(cores.single.disposed, isTrue);

      await c.retryRegister();
      expect(c.step, LoginStep.done);
      expect(cores, hasLength(2));
      expect(cores.last.disposed, isFalse);
    });
  });

  test('UUIDv7: 16 byte, version 7, variant 10, thời gian đúng, tăng dần theo thời gian', () {
    final t = DateTime.utc(2026, 11, 7, 12);
    final a = newUuidV7(now: t);
    expect(a.length, 16);
    expect(a[6] >> 4, 7);
    expect(a[8] >> 6, 2);
    var ms = 0;
    for (var i = 0; i < 6; i++) {
      ms = ms * 256 + a[i];
    }
    expect(ms, t.millisecondsSinceEpoch);
    final b = newUuidV7(now: t.add(const Duration(milliseconds: 1)));
    expect(a.sublist(0, 6).join(','), isNot(b.sublist(0, 6).join(',')));
    expect(newUuidV7(now: t), isNot(a), reason: 'phần ngẫu nhiên phải khác nhau');
  });

  testWidgets('màn hình: nhập số, nhập mã, vào màn đã đăng nhập', (tester) async {
    final srv = FakeServer();
    await tester.pumpWidget(ByoChatApp(api: srv.api, openCore: () async => FakeCore()));
    await tester.pumpAndSettle(); // chờ bước khôi phục phiên (không có gì để khôi phục)

    await tester.enterText(find.byKey(const Key('contact-field')), '+84901234567');
    await tester.tap(find.byKey(const Key('request-otp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('code-field')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('code-field')), '000000');
    await tester.tap(find.byKey(const Key('verify-otp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-error')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('code-field')), '123456');
    await tester.tap(find.byKey(const Key('verify-otp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('signed-in')), findsOneWidget);
    expect(find.text('KeyPackage trên máy chủ: 100'), findsOneWidget);
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
