import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import 'chat_page.dart';
import 'contact_page.dart';
import 'group_pages.dart';
import 'conversations_page.dart';
import 'calls_page.dart';
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
  bool _info = false;
  bool _calls = false; // cột giữa là lịch sử cuộc gọi (S-14) thay vì danh sách chat

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('desktop-shell'),
      backgroundColor: Colors.white,
      body: Row(
        children: [
          DesktopRail(
            callsActive: _calls,
            onChat: () => setState(() => _calls = false),
            onCalls: () => setState(() => _calls = true),
            onSettings: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(engine: widget.engine, onLogout: widget.onLogout),
              ),
            ),
          ),
          if (_calls)
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 480,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(border: Border(right: BorderSide(color: Ui.border))),
                      child: CallsPage(
                        engine: widget.engine,
                        desktop: true,
                        onOpen: (convHex) => setState(() {
                          _calls = false;
                          _selected = convHex;
                          _info = false;
                        }),
                      ),
                    ),
                  ),
                  const Expanded(
                    child: ColoredBox(
                      color: Ui.surfaceAlt,
                      child: Center(child: Text('Chọn một cuộc gọi để xem chi tiết', key: Key('calls-detail-empty'), style: TextStyle(fontSize: 15, color: Ui.muted))),
                    ),
                  ),
                ],
              ),
            )
          else ...[
          SizedBox(
            width: 340,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border.symmetric(vertical: BorderSide(color: Ui.border, width: 0.5)),
              ),
              child: ConversationsPage(
                engine: widget.engine,
                onLogout: widget.onLogout,
                selectedHexId: _selected,
                onOpen: (c) => setState(() {
                  _selected = c.hexId;
                  _info = false;
                }),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.engine,
              builder: (context, _) {
                final conv = widget.engine.conversations.where((c) => c.hexId == _selected).firstOrNull;
                if (conv == null) {
                  return const Center(
                    child: Text(
                      'Chọn một cuộc trò chuyện để bắt đầu',
                      key: Key('desktop-empty'),
                      style: TextStyle(fontSize: 15, color: Ui.muted),
                    ),
                  );
                }
                return Row(
                  children: [
                    Expanded(
                      child: ChatPage(
                        key: ValueKey(conv.hexId),
                        engine: widget.engine,
                        conv: conv,
                        embedded: true,
                        onInfo: () => setState(() => _info = !_info),
                      ),
                    ),
                    if (_info)
                      conv.isGroup ? GroupInfoPage(engine: widget.engine, conv: conv, embedded: true) : ContactPanel(name: conv.title),
                  ],
                );
              },
            ),
          ),
          ],
        ],
      ),
    );
  }
}

class DesktopRail extends StatelessWidget {
  const DesktopRail({super.key, required this.onSettings, this.settingsActive = false, this.onChat, this.onCalls, this.callsActive = false});
  final VoidCallback? onChat, onCalls;
  final bool settingsActive, callsActive;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        color: Ui.surfaceAlt,
        border: Border(right: BorderSide(color: Ui.border)),
      ),
      child: Column(
        children: [
          InkWell(
            key: const Key('rail-chat'),
            borderRadius: BorderRadius.circular(12),
            onTap: onChat,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: settingsActive || callsActive ? null : Ui.primary, borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.chat_bubble_outline, size: 22, color: settingsActive || callsActive ? Ui.muted : Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            key: const Key('rail-calls'),
            borderRadius: BorderRadius.circular(12),
            onTap: onCalls,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: callsActive ? Ui.primary : null, borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.videocam_outlined, size: 22, color: callsActive ? Colors.white : Ui.muted),
            ),
          ),
          const Spacer(),
          IconButton(
            key: const Key('rail-settings'),
            tooltip: 'Cài đặt',
            onPressed: onSettings,
            style: IconButton.styleFrom(
              backgroundColor: settingsActive ? Ui.primary : null,
              fixedSize: const Size.square(44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: Icon(Icons.settings_outlined, size: 22, color: settingsActive ? Colors.white : Ui.muted),
          ),
        ],
      ),
    );
  }
}
