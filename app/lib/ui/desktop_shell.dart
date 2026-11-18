import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import 'chat_page.dart';
import 'conversations_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// Bề rộng từ đó dùng bố cục ba cột của Desktop (docs/ui/Desktop-Inbox).
const desktopBreakpoint = 900.0;

/// Bố cục Desktop: thanh điều hướng 72, danh sách 340, khung chat chiếm phần còn lại.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.engine, this.onLogout});

  final ChatEngine engine;
  final VoidCallback? onLogout;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('desktop-shell'),
      backgroundColor: Colors.white,
      body: Row(
        children: [
          _Rail(onSettings: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(engine: widget.engine, onLogout: widget.onLogout)))),
          SizedBox(
            width: 340,
            child: DecoratedBox(
              decoration: const BoxDecoration(border: Border.symmetric(vertical: BorderSide(color: Ui.border, width: 0.5))),
              child: ConversationsPage(engine: widget.engine, onLogout: widget.onLogout, selectedHexId: _selected, onOpen: (c) => setState(() => _selected = c.hexId)),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.engine,
              builder: (context, _) {
                final conv = widget.engine.conversations.where((c) => c.hexId == _selected).firstOrNull;
                if (conv == null) {
                  return const Center(child: Text('Chọn một cuộc trò chuyện để bắt đầu', key: Key('desktop-empty'), style: TextStyle(fontSize: 15, color: Ui.muted)));
                }
                return ChatPage(key: ValueKey(conv.hexId), engine: widget.engine, conv: conv);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(color: Ui.surfaceAlt, border: Border(right: BorderSide(color: Ui.border))),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: Ui.primary, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.chat_bubble_outline, size: 22, color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Opacity(opacity: 0.45, child: SizedBox(width: 44, height: 44, child: Icon(Icons.videocam_outlined, size: 22, color: Ui.muted))),
          const Spacer(),
          IconButton(key: const Key('rail-settings'), tooltip: 'Cài đặt', onPressed: onSettings, icon: const Icon(Icons.settings_outlined, size: 22, color: Ui.muted)),
        ],
      ),
    );
  }
}
