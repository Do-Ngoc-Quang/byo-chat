// Chạy trên thiết bị/emulator thật hoặc Chrome: `flutter test integration_test -d <id>`.
// Chứng minh cầu nối chatcore nạp và chạy MLS trên nền tảng đích (Android: FFI, Web: WASM).
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/main.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'chat_e2e.dart';
import 'login_e2e.dart';
import 'persist_e2e.dart';
import 'mls_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('app mở ra màn đăng nhập', (tester) async {
    await tester.pumpWidget(ByoChatApp(api: ChatApi(ConnectClient(Uri.parse('http://127.0.0.1:1')))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-otp')), findsOneWidget);
  });

  test('phiên bản lõi thật', () async {
    final core = await openChatCore();
    expect(await core.version(), matches(RegExp(r'^\d+\.\d+\.\d+$')));
    await core.dispose();
  });

  test('MLS 1-1, External Commit, SFrame qua cầu nối', () => runMlsScenario(openChatCore));
  test('credential và KeyPackage hàng loạt qua cầu nối', () => runCredentialScenario(openChatCore));

  // Cần server thật: --dart-define=CHAT_API=http://10.0.2.2:8080 (Android) và CHAT_DEV_OTP_CODE=123456 phía server.
  const apiUrl = String.fromEnvironment('CHAT_API');
  test('đăng nhập OTP + đăng ký thiết bị với server thật', () => runLoginE2E(Uri.parse(apiUrl)),
      skip: apiUrl.isEmpty ? 'đặt --dart-define=CHAT_API để chạy' : false);
  test('lưu bền + khôi phục với server thật (Keystore và tệp thật của thiết bị)',
      () async => runPersistE2E(Uri.parse(apiUrl), SecureSecretStore(), await openBlobStore()),
      skip: apiUrl.isEmpty ? 'đặt --dart-define=CHAT_API để chạy' : false);
  test('chat 1-1 hai thiết bị với server thật qua WebSocket', () => runChatE2E(Uri.parse(apiUrl)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: apiUrl.isEmpty ? 'đặt --dart-define=CHAT_API để chạy' : false);
}
