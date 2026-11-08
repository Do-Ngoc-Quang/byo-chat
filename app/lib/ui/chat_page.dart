import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import 'group_pages.dart';
import 'theme.dart';

/// Khung chat theo docs/ui (Mobile-Chat.dc.html): thanh đầu có avatar, nền xám nhạt, bong bóng bo 18, ô nhập tròn.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.engine, required this.conv});

  final ChatEngine engine;
  final ConvState conv;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    await widget.engine.sendText(widget.conv.hexId, t);
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conv;
    return Scaffold(
      key: const Key('chat-page'),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Avatar(conv.title),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conv.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  if (conv.isGroup)
                    const Text(
                      'Nhóm',
                      style: TextStyle(fontSize: 12, color: Ui.muted, fontWeight: FontWeight.w400),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (conv.isGroup)
            IconButton(
              key: const Key('group-info'),
              tooltip: 'Thông tin nhóm',
              icon: const Icon(Icons.info_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GroupInfoPage(engine: widget.engine, conv: conv),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Ui.surfaceAlt,
              child: ListenableBuilder(
                listenable: widget.engine,
                builder: (context, _) {
                  final msgs = widget.engine.messages(conv.hexId);
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final k = msgs.length - 1 - i;
                      final m = msgs[k];
                      return _Bubble(
                        m,
                        who: m.sender == null ? null : widget.engine.displayName(m.sender!),
                        lastOfRun: k == msgs.length - 1 || msgs[k + 1].mine != m.mine,
                      );
                    },
                  );
                },
              ),
            ),
          ),
          if (conv.removed)
            const _Banner('Bạn không còn trong nhóm này.', key: Key('removed-banner'))
          else if (conv.leaving)
            const _Banner('Đang chờ quản trị viên xác nhận bạn rời nhóm…', key: Key('leaving-banner'))
          else
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Ui.border)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('message-field'),
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          style: const TextStyle(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: 'Nhập tin nhắn',
                            filled: true,
                            fillColor: Ui.surface,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        key: const Key('send'),
                        tooltip: 'Gửi',
                        onPressed: _send,
                        style: IconButton.styleFrom(
                          backgroundColor: Ui.primary,
                          foregroundColor: Colors.white,
                          fixedSize: const Size.square(Ui.tap),
                        ),
                        icon: const Icon(Icons.arrow_upward, size: 22),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: Ui.border)),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 14, color: Ui.muted),
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {this.who, this.lastOfRun = true});

  final ChatMessage m;

  /// Tên người gửi (chỉ trong nhóm, tin của người khác).
  final String? who;

  /// Tin cuối của một chuỗi cùng người gửi: góc đuôi nhọn (4px) theo thiết kế.
  final bool lastOfRun;

  static String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final broken = m.state == MsgState.undecryptable;
    final text = broken ? 'Không giải mã được tin này' : m.text;
    final status = switch (m.state) {
      MsgState.pending => 'Đang gửi',
      MsgState.failed => 'Gửi lỗi',
      _ => '',
    };
    const r = Radius.circular(Ui.radiusBubble), tail = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: m.mine || !lastOfRun ? r : tail,
      bottomRight: !m.mine || !lastOfRun ? r : tail,
    );
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: Key('msg-${m.id}'),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: m.mine ? Ui.primary : Colors.white,
          border: m.mine ? null : Border.all(color: Ui.border),
          borderRadius: radius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (who != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  who!,
                  key: Key('from-${m.id}'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Ui.avatarFg),
                ),
              ),
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                color: m.mine ? Colors.white : Ui.text,
                fontStyle: broken ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              status.isEmpty ? _clock(m.tsMs) : status,
              style: TextStyle(fontSize: 11, color: m.mine ? const Color(0xCCFFFFFF) : Ui.muted),
            ),
          ],
        ),
      ),
    );
  }
}
