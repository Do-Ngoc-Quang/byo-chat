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
import 'theme.dart';

/// Danh sách hội thoại theo docs/ui (Main.dc.html): tiêu đề "Tin nhắn", ô tìm, lọc Tất cả/Nhóm, hàng 72px.
class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key, required this.engine, this.onLogout});

  final ChatEngine engine;
  final VoidCallback? onLogout;

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  String _query = '';
  bool _groupsOnly = false;

  ChatEngine get engine => widget.engine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final all = engine.conversations;
        final q = _query.trim().toLowerCase();
        final convs = all.where((c) => (!_groupsOnly || c.isGroup) && (q.isEmpty || c.title.toLowerCase().contains(q))).toList();
        return Scaffold(
          key: const Key('conversations-page'),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Tin nhắn', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
                      ),
                      _RoundButton(
                        key: const Key('new-chat'),
                        tooltip: 'Cuộc trò chuyện mới',
                        icon: Icons.edit_outlined,
                        onPressed: () => _newChat(context),
                      ),
                      const SizedBox(width: 4),
                      PopupMenuButton<String>(
                        key: const Key('menu'),
                        tooltip: 'Menu',
                        icon: const Icon(Icons.more_horiz),
                        onSelected: (v) => _menu(context, v),
                        itemBuilder: (_) => [
                          const PopupMenuItem(key: Key('menu-group'), value: 'group', child: Text('Nhóm mới')),
                          const PopupMenuItem(key: Key('menu-devices'), value: 'devices', child: Text('Thiết bị của tôi')),
                          const PopupMenuItem(key: Key('menu-backup'), value: 'backup', child: Text('Sao lưu')),
                          if (widget.onLogout != null) const PopupMenuItem(key: Key('logout'), value: 'logout', child: Text('Đăng xuất')),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                  child: Text(
                    _status(engine.connection),
                    key: const Key('connection-status'),
                    style: const TextStyle(fontSize: 12, color: Ui.muted),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: TextField(
                    key: const Key('search-field'),
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Tìm trong cuộc trò chuyện',
                      prefixIcon: const Icon(Icons.search, color: Ui.muted),
                      filled: true,
                      fillColor: Ui.surface,
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: const BorderSide(color: Ui.primary, width: 1.5),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Row(
                    children: [
                      _Chip(
                        key: const Key('filter-all'),
                        label: 'Tất cả',
                        selected: !_groupsOnly,
                        onTap: () => setState(() => _groupsOnly = false),
                      ),
                      const SizedBox(width: 8),
                      _Chip(
                        key: const Key('filter-groups'),
                        label: 'Nhóm',
                        selected: _groupsOnly,
                        onTap: () => setState(() => _groupsOnly = true),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: convs.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              all.isEmpty ? 'Chưa có cuộc trò chuyện. Bấm nút soạn tin để nhắn cho ai đó.' : 'Không có kết quả.',
                              key: const Key('empty'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Ui.muted),
                            ),
                          ),
                        )
                      : ListView(
                          children: [for (final c in convs) _Row(engine: engine, conv: c)],
                        ),
                ),
              ],
            ),
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
        widget.onLogout?.call();
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

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(backgroundColor: Ui.surface, fixedSize: const Size.square(Ui.tap)),
    icon: Icon(icon, size: 22),
  );
}

/// Chip lọc: đang chọn nền #14171F chữ trắng, còn lại nền #F0F2F5 (thiết kế).
class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: selected ? Ui.text : Ui.surface, borderRadius: BorderRadius.circular(18)),
      child: Text(
        label,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: selected ? Colors.white : Ui.text),
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.engine, required this.conv});

  final ChatEngine engine;
  final ConvState conv;

  static String lastLine(List<ChatMessage> m) {
    if (m.isEmpty) return '';
    final l = m.last;
    return switch (l.state) {
      MsgState.undecryptable => 'Không giải mã được tin này',
      _ => l.mine ? 'Bạn: ${l.text}' : l.text,
    };
  }

  @override
  Widget build(BuildContext context) {
    final msgs = engine.messages(conv.hexId);
    return InkWell(
      key: Key('conv-${conv.hexId}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(engine: engine, conv: conv),
        ),
      ),
      child: SizedBox(
        height: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Avatar(conv.title, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conv.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          shortTime(msgs.isEmpty ? conv.lastActivityMs : msgs.last.tsMs),
                          style: const TextStyle(fontSize: 12, color: Ui.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lastLine(msgs),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: Ui.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
