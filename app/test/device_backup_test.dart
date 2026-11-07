import 'dart:typed_data';

import 'package:byo_chat/auth/link_controller.dart';
import 'package:byo_chat/auth/login_controller.dart';
import 'package:byo_chat/chat/backup.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart' show TokenPair;
import 'package:byo_chat/gen/chat/v1/services.pbenum.dart';
import 'package:byo_chat/ui/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_server.dart';

Uint8List _b(int n, int v) => Uint8List.fromList(List.filled(n, v));

void main() {
  test('LinkOffer: mã QR mã hóa rồi đọc lại đúng, từ chối mã hỏng', () {
    final o = LinkOffer(_b(16, 1), _b(16, 2), _b(32, 3), _b(32, 4), '123456');
    final r = LinkOffer.decode(o.encode());
    expect(r.linkId, o.linkId);
    expect(r.deviceId, o.deviceId);
    expect(r.devicePublicKey, o.devicePublicKey);
    expect(r.ephemeralPublicKey, o.ephemeralPublicKey);
    expect(r.shortCode, '123456');
    expect(LinkOffer.decode('  ${o.encode()}\n').shortCode, '123456'); // dán có khoảng trắng
    expect(() => LinkOffer.decode('khong-phai-ma'), throwsA(anything));
    expect(() => LinkOffer.decode(LinkOffer(_b(8, 1), _b(16, 2), _b(32, 3), _b(32, 4), '1').encode()), throwsFormatException);
  });

  test('recovery key: định dạng chia nhóm và đọc lại; từ chối sai định dạng', () {
    final k = Uint8List.fromList(List.generate(32, (i) => i * 7));
    final s = BackupService.formatKey(k);
    expect(RegExp(r'^([0-9a-f]{4}-){15}[0-9a-f]{4}$').hasMatch(s), isTrue);
    expect(BackupService.parseKey(s), k);
    expect(BackupService.parseKey(s.toUpperCase().replaceAll('-', ' ')), k); // chữ hoa, khoảng trắng
    for (final bad in ['', 'abc', '${s}0', s.replaceFirst('0', 'z')]) {
      expect(() => BackupService.parseKey(bad), throwsA(isA<BackupException>()), reason: bad);
    }
  });

  testWidgets('đăng nhập: luôn có nút liên kết; tài khoản đã có thì thêm nút khôi phục', (tester) async {
    final srv = FakeServer(newAccount: false);
    final c = LoginController(api: srv.api, openCore: () async => FakeCore());
    await tester.pumpWidget(MaterialApp(home: LoginPage(controller: c)));
    expect(find.byKey(const Key('open-link')), findsOneWidget);
    expect(find.byKey(const Key('open-restore')), findsNothing);

    await c.requestOtp(OtpChannel.OTP_CHANNEL_SMS, '+84901234567');
    await c.verifyCode('123456');
    await tester.pump();
    expect(c.existing, isTrue);
    expect(c.existingTicket, isNotNull);
    expect(find.byKey(const Key('open-restore')), findsOneWidget);
    expect(find.byKey(const Key('login-error')), findsOneWidget);
  });

  test('adopt: nhận phiên từ liên kết/khôi phục và đánh dấu cần vào hội thoại', () {
    final c = LoginController(api: FakeServer().api, openCore: () async => FakeCore());
    expect(c.needsJoin, isFalse);
    c.adopt(Session(_b(16, 1), _b(16, 2), FakeCore(), TokenPair(accessToken: 't', refreshToken: 'r'), 0));
    expect(c.session, isNotNull);
    expect(c.step, LoginStep.done);
    expect(c.needsJoin, isTrue);
    expect(c.existing, isFalse);
  });
}
