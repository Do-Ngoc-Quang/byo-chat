import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import 'group_pages.dart';

/// Màn hình chat 1-1: danh sách tin (mới nhất ở dưới) và ô nhập.
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
    return Scaffold(
      key: const Key('chat-page'),
      appBar: AppBar(
        title: Text(widget.conv.title),
        actions: [
          if (widget.conv.isGroup)
            IconButton(
              key: const Key('group-info'),
              tooltip: 'Thông tin nhóm',
              icon: const Icon(Icons.info_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GroupInfoPage(engine: widget.engine, conv: widget.conv),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: widget.engine,
              builder: (context, _) {
                final msgs = widget.engine.messages(widget.conv.hexId);
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[msgs.length - 1 - i];
                    return _Bubble(m, who: m.sender == null ? null : widget.engine.displayName(m.sender!));
                  },
                );
              },
            ),
          ),
          if (widget.conv.removed)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Bạn không còn trong nhóm này.', key: Key('removed-banner')),
            )
          else if (widget.conv.leaving)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Đang chờ quản trị viên xác nhận bạn rời nhóm…', key: Key('leaving-banner')),
            )
          else
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('message-field'),
                        controller: _text,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(hintText: 'Nhập tin nhắn', border: OutlineInputBorder()),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(key: const Key('send'), tooltip: 'Gửi', icon: const Icon(Icons.send), onPressed: _send),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {this.who});

  final ChatMessage m;

  /// Tên người gửi (chỉ trong nhóm, tin của người khác).
  final String? who;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final broken = m.state == MsgState.undecryptable;
    final text = broken ? 'Không giải mã được tin này' : m.text;
    final status = switch (m.state) {
      MsgState.pending => ' · đang gửi',
      MsgState.failed => ' · gửi lỗi',
      _ => '',
    };
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: Key('msg-${m.id}'),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: m.mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (who != null) Text(who!, key: Key('from-${m.id}'), style: Theme.of(context).textTheme.labelSmall),
            Text(text, style: broken ? const TextStyle(fontStyle: FontStyle.italic) : null),
            if (status.isNotEmpty) Text(status.substring(3), style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
