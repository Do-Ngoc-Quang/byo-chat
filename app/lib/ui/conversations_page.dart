import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/services.pbenum.dart';
import '../net/connect_client.dart';
import '../net/gateway_client.dart';
import 'chat_page.dart';

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
              if (onLogout != null) IconButton(key: const Key('logout'), tooltip: 'Đăng xuất', icon: const Icon(Icons.logout), onPressed: onLogout),
            ],
          ),
          body: convs.isEmpty
              ? const Center(child: Text('Chưa có cuộc trò chuyện. Bấm + để nhắn cho ai đó.', key: Key('empty')))
              : ListView(
                  children: [
                    for (final c in convs)
                      ListTile(
                        key: Key('conv-${c.hexId}'),
                        leading: CircleAvatar(child: Text(c.title.isEmpty ? '?' : c.title.characters.first)),
                        title: Text(c.title),
                        subtitle: Text(_lastLine(engine.messages(c.hexId)), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatPage(engine: engine, conv: c))),
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

  Future<void> _newChat(BuildContext context) async {
    final ctl = TextEditingController();
    var channel = OtpChannel.OTP_CHANNEL_SMS;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final dest = await showDialog<(OtpChannel, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Cuộc trò chuyện mới'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<OtpChannel>(
              segments: const [
                ButtonSegment(value: OtpChannel.OTP_CHANNEL_SMS, label: Text('Số điện thoại')),
                ButtonSegment(value: OtpChannel.OTP_CHANNEL_EMAIL, label: Text('Email')),
              ],
              selected: {channel},
              onSelectionChanged: (s) => setState(() => channel = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('peer-field'),
              controller: ctl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: channel == OtpChannel.OTP_CHANNEL_SMS ? 'Số điện thoại (+84...)' : 'Email',
                border: const OutlineInputBorder(),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
            FilledButton(key: const Key('peer-ok'), onPressed: () => Navigator.pop(ctx, (channel, ctl.text)), child: const Text('Bắt đầu')),
          ],
        ),
      ),
    );
    if (dest == null || dest.$2.trim().isEmpty) return;
    try {
      final c = await engine.openDirect(dest.$1, dest.$2);
      nav.push(MaterialPageRoute<void>(builder: (_) => ChatPage(engine: engine, conv: c)));
    } on ConnectException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.errorCode == ErrorCode.ERROR_CODE_NOT_FOUND ? 'Không tìm thấy người dùng này.' : 'Lỗi: ${e.message}')));
    } on IdentityChangedException {
      messenger.showSnackBar(const SnackBar(content: Text('Khóa bảo mật của người này đã thay đổi. Hãy xác minh lại trước khi nhắn.')));
    } on ChatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
