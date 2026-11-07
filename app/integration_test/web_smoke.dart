// Chạy kịch bản MLS trong trình duyệt và in kết quả lên màn hình (Flutter chưa hỗ trợ
// integration_test trên Web nếu không có chromedriver):
//   flutter run -d chrome --target integration_test/web_smoke.dart
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/storage/blob_store.dart';
import 'package:byo_chat/storage/secret_store.dart';
import 'package:flutter/material.dart';

import 'chat_e2e.dart';
import 'backup_e2e.dart';
import 'revoke_e2e.dart';
import 'login_e2e.dart';
import 'persist_e2e.dart';
import 'mls_scenario.dart';

void main() => runApp(const _Smoke());

const _apiUrl = String.fromEnvironment('CHAT_API');

/// MLS + credential luôn chạy; đăng nhập thật chỉ khi có --dart-define=CHAT_API (server dev, đã bật CORS cho origin này).
Future<void> _run() async {
  await runMlsScenario(openChatCore);
  await runCredentialScenario(openChatCore);
  if (_apiUrl.isNotEmpty) {
    await runLoginE2E(Uri.parse(_apiUrl));
    await runPersistE2E(Uri.parse(_apiUrl), SecureSecretStore(), await openBlobStore());
    await runChatE2E(Uri.parse(_apiUrl));
    await runGroupE2E(Uri.parse(_apiUrl));
    await runLinkE2E(Uri.parse(_apiUrl));
    await runRevokeE2E(Uri.parse(_apiUrl));
    await runBackupE2E(Uri.parse(_apiUrl));
  }
}

class _Smoke extends StatelessWidget {
  const _Smoke();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FutureBuilder<void>(
            future: _run(),
            builder: (_, s) => Text(
              s.hasError ? 'MLS LOI: ${s.error}' : s.connectionState == ConnectionState.done ? 'MLS OK' : 'dang chay',
            ),
          ),
        ),
      ),
    );
  }
}
