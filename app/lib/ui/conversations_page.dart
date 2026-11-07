import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../net/gateway_client.dart';
import 'backup_pages.dart';
import 'chat_page.dart';
import 'contact_dialog.dart';
import 'device_pages.dart';
import 'errors.dart';
import 'group_pages.dart';

/// Danh sách hội thoại (man-hinh.md) và nút bắt đầu chat bằng số điện thoại/email.
class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key, required this.engine, this.onLogout});

  final ChatEngine engine;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final convs = engine.conversations;
        return Scaffold(
          key: const Key('conversations-page'),
          appBar: AppBar(
            title: const Text('BYO Chat'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(20),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_status(engine.connection), key: const Key('connection-status'), style: Theme.of(context).textTheme.labelSmall),
              ),
            ),
            actions: [
              PopupMenuButton<String>(
                key: const Key('menu'),
                onSelected: (v) => _menu(context, v),
                itemBuilder: (_) => [
                  const PopupMenuItem(key: Key('menu-group'), value: 'group', child: Text('Nhóm mới')),
                  const PopupMenuItem(key: Key('menu-devices'), value: 'devices', child: Text('Thiết bị của tôi')),
                  const PopupMenuItem(key: Key('menu-backup'), value: 'backup', child: Text('Sao lưu')),
                  if (onLogout != null) const PopupMenuItem(key: Key('logout'), value: 'logout', child: Text('Đăng xuất')),
                ],
              ),
            ],
          ),
          body: convs.isEmpty
              ? const Center(child: Text('Chưa có cuộc trò chuyện. Bấm + để nhắn cho ai đó.', key: Key('empty')))
              : ListView(
                  children: [
                    for (final c in convs)
                      ListTile(
                        key: Key('conv-${c.hexId}'),
                        leading: CircleAvatar(
                          child: c.isGroup ? const Icon(Icons.group) : Text(c.title.isEmpty ? '?' : c.title.characters.first),
                        ),
                        title: Text(c.title),
                        subtitle: Text(_lastLine(engine.messages(c.hexId)), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChatPage(engine: engine, conv: c),
                          ),
                        ),
                      ),
                  ],
                ),
          floatingActionButton: FloatingActionButton(
            key: const Key('new-chat'),
            tooltip: 'Cuộc trò chuyện mới',
            onPressed: () => _newChat(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  static String _status(GatewayState s) => switch (s) {
    GatewayState.online => 'Đã kết nối',
    GatewayState.syncing => 'Đang đồng bộ…',
    GatewayState.connecting || GatewayState.authenticating => 'Đang kết nối…',
    GatewayState.backoff || GatewayState.disconnected => 'Mất kết nối, đang thử lại…',
    GatewayState.stopped => 'Đã dừng',
  };

  static String _lastLine(List<ChatMessage> m) {
    if (m.isEmpty) return '';
    final l = m.last;
    return switch (l.state) {
      MsgState.undecryptable => 'Không giải mã được tin này',
      _ => l.mine ? 'Bạn: ${l.text}' : l.text,
    };
  }

  void _menu(BuildContext context, String v) {
    final nav = Navigator.of(context);
    switch (v) {
      case 'group':
        nav.push(MaterialPageRoute<void>(builder: (_) => GroupCreatePage(engine: engine)));
      case 'devices':
        nav.push(MaterialPageRoute<void>(builder: (_) => DevicesPage(engine: engine)));
      case 'backup':
        nav.push(MaterialPageRoute<void>(builder: (_) => BackupPage(engine: engine)));
      case 'logout':
        onLogout?.call();
    }
  }

  Future<void> _newChat(BuildContext context) async {
    final nav = Navigator.of(context);
    final dest = await askContact(context, title: 'Cuộc trò chuyện mới', ok: 'Bắt đầu');
    if (dest == null || !context.mounted) return;
    ConvState? c;
    final ok = await guarded(context, () async => c = await engine.openDirect(dest.$1, dest.$2));
    if (ok && c != null) {
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(engine: engine, conv: c!),
        ),
      );
    }
  }
}
