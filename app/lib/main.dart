import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'auth/login_controller.dart';
import 'chat/chat_engine.dart';
import 'core/chatcore.dart';
import 'net/api.dart';
import 'net/connect_client.dart';
import 'storage/blob_store.dart';
import 'storage/secret_store.dart';
import 'storage/session_store.dart';
import 'ui/conversations_page.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

/// Địa chỉ server: `--dart-define=CHAT_API=http://host:8080`. Mặc định: Web dùng localhost,
/// emulator Android dùng 10.0.2.2 (máy chủ của emulator).
const _apiFromEnv = String.fromEnvironment('CHAT_API');

Uri defaultApiUrl() {
  if (_apiFromEnv.isNotEmpty) return Uri.parse(_apiFromEnv);
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return Uri.parse('http://10.0.2.2:8080');
  return Uri.parse('http://localhost:8080');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SessionStore(secrets: SecureSecretStore(), blobs: await openBlobStore());
  runApp(ByoChatApp(api: ChatApi(ConnectClient(defaultApiUrl())), store: store));
}

class ByoChatApp extends StatefulWidget {
  const ByoChatApp({super.key, required this.api, this.openCore = openChatCore, this.store, this.enableChat = true});

  final ChatApi api;

  /// Bật chat (WebSocket + hội thoại). Test giao diện đăng nhập tắt đi để không mở kết nối.
  final bool enableChat;

  /// Lưu bền khóa và phiên; null thì không lưu (test).
  final SessionStore? store;

  /// Tiêm được để test thay lõi thật.
  final Future<ChatCore> Function() openCore;

  @override
  State<ByoChatApp> createState() => _ByoChatAppState();
}

class _ByoChatAppState extends State<ByoChatApp> {
  late final LoginController _login = LoginController(api: widget.api, openCore: widget.openCore, store: widget.store);
  late final Future<bool> _restored;
  ChatEngine? _engine;

  @override
  void initState() {
    super.initState();
    _restored = _login.restore();
  }

  @override
  void dispose() {
    _engine?.dispose();
    _login.dispose();
    super.dispose();
  }

  /// Tạo engine một lần cho mỗi phiên và khởi động kết nối.
  ChatEngine _engineFor(Session s) {
    final e = _engine;
    if (e != null && identical(e.session, s)) return e;
    e?.dispose();
    final n = ChatEngine(session: s, api: widget.api, store: widget.store ?? _noStore, apiBase: widget.api.client.baseUrl);
    n.onRevoked = _logout; // mã đóng 4003: thiết bị bị thu hồi, xóa dữ liệu
    _engine = n;
    n.start();
    return n;
  }

  Future<void> _logout() async {
    final e = _engine;
    _engine = null;
    await e?.stop();
    await _login.logout();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BYO Chat',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: FutureBuilder<bool>(
        future: _restored,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator(key: Key('restoring'))));
          }
          return ListenableBuilder(
            listenable: _login,
            builder: (context, _) {
              final s = _login.session;
              if (s == null) return LoginPage(controller: _login);
              if (!widget.enableChat || widget.store == null) return HomePage(session: s, onLogout: _login.logout);
              return ConversationsPage(engine: _engineFor(s), onLogout: _logout);
            },
          );
        },
      ),
    );
  }
}

/// Chỉ để thỏa kiểu khi không có kho (chat bị tắt nên không bao giờ dùng tới).
final SessionStore _noStore = SessionStore(secrets: MemorySecretStore(), blobs: MemoryBlobStore());
