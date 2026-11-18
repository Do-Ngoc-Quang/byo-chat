import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../gen/chat/v1/services.pbenum.dart';
import 'chat_page.dart';
import 'errors.dart';
import 'desktop_shell.dart';
import 'group_pages.dart';
import 'theme.dart';

/// Trò chuyện mới (S-09, docs/ui/Mobile-NewChat): ô nhập số điện thoại/email, "Tạo nhóm mới", danh sách gần đây.
/// Bản vẽ có mục "Danh bạ"; app chưa có danh bạ nên hiện các cuộc trò chuyện 1-1 đã có (xem docs/notes.md).
class NewChatPage extends StatelessWidget {
  const NewChatPage({super.key, required this.engine});

  final ChatEngine engine;

  void _openChat(BuildContext context, ConvState c) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(engine: engine, conv: c),
      ),
    );
  }

  Future<void> _submit(BuildContext context, String raw) async {
    final dest = raw.trim();
    if (dest.isEmpty) return;
    final channel = dest.contains('@') ? OtpChannel.OTP_CHANNEL_EMAIL : OtpChannel.OTP_CHANNEL_SMS;
    ConvState? c;
    final ok = await guarded(context, () async => c = await engine.openDirect(channel, dest));
    if (ok && c != null && context.mounted) _openChat(context, c!);
  }

  @override
  Widget build(BuildContext context) {
    final recent = engine.conversations.where((c) => !c.isGroup).toList();
    return NewChatView(
      recent: [for (final c in recent) c.title],
      onClose: () => Navigator.of(context).maybePop(),
      onSubmit: (v) => _submit(context, v),
      onGroup: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => GroupCreatePage(engine: engine))),
      onPickRecent: (i) => _openChat(context, recent[i]),
    );
  }
}

/// Phần giao diện thuần (tách khỏi engine để chụp ảnh đối chiếu được).
class NewChatView extends StatefulWidget {
  const NewChatView({super.key, required this.recent, this.onClose, this.onSubmit, this.onGroup, this.onPickRecent});

  final List<String> recent;
  final VoidCallback? onClose, onGroup;
  final ValueChanged<String>? onSubmit;
  final ValueChanged<int>? onPickRecent;

  @override
  State<NewChatView> createState() => _NewChatViewState();
}

class _NewChatViewState extends State<NewChatView> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String _initials(String t) {
    final w = t.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (w.isEmpty) return '?';
    if (w.length == 1) return w.first.characters.take(2).toString().toUpperCase();
    return (w.first.characters.first + w.last.characters.first).toUpperCase();
  }

  Widget _title(double size, EdgeInsets pad) => Padding(
    padding: pad,
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Trò chuyện mới',
            style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, letterSpacing: -0.3),
          ),
        ),
        IconButton(
          key: const Key('new-chat-close'),
          tooltip: 'Đóng',
          onPressed: widget.onClose,
          style: IconButton.styleFrom(fixedSize: const Size.square(Ui.tap), backgroundColor: pad.left == 0 ? Ui.surface : null),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );

  Widget _field(EdgeInsets pad) => Padding(
    padding: pad,
    child: TextField(
      key: const Key('peer-field'),
      controller: _ctl,
      autofocus: true,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.go,
      onChanged: (_) => setState(() {}),
      onSubmitted: widget.onSubmit,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        hintText: 'Nhập số điện thoại hoặc email',
        prefixIcon: const Icon(Icons.search, color: Ui.muted),
        filled: true,
        fillColor: Ui.surface,
        contentPadding: EdgeInsets.zero,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: Ui.primary, width: 1.5),
        ),
      ),
    ),
  );

  List<Widget> _rows() => [
    if (_ctl.text.trim().isNotEmpty)
      _Line(
        key: const Key('peer-ok'),
        height: 60,
        avatar: const _Circle(
          bg: Ui.accentBg,
          child: Icon(Icons.send_outlined, size: 20, color: Ui.primary),
        ),
        title: 'Nhắn tới ${_ctl.text.trim()}',
        titleColor: Ui.primary,
        onTap: () => widget.onSubmit?.call(_ctl.text),
      ),
    _Line(
      key: const Key('new-group'),
      height: 60,
      avatar: const _Circle(
        bg: Ui.accentBg,
        child: Icon(Icons.group_add_outlined, size: 20, color: Ui.primary),
      ),
      title: 'Tạo nhóm mới',
      titleColor: Ui.primary,
      onTap: widget.onGroup,
    ),
    if (widget.recent.isNotEmpty) ...[
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Gần đây',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted),
        ),
      ),
      for (var i = 0; i < widget.recent.length; i++)
        _Line(
          key: Key('recent-$i'),
          height: 64,
          avatar: Avatar(_initials(widget.recent[i]), size: 44),
          title: widget.recent[i],
          onTap: () => widget.onPickRecent?.call(i),
        ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    // Desktop (Desktop-NewChat): hộp thoại 480 bo 24 giữa màn, nền phủ mờ.
    if (MediaQuery.sizeOf(context).width >= desktopBreakpoint) {
      return Scaffold(
        key: const Key('new-chat-page'),
        backgroundColor: Ui.surfaceAlt,
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0x7314171F))),
            Center(
              child: Container(
                key: const Key('new-chat-dialog'),
                width: 480,
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 48),
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _title(22, const EdgeInsets.only(bottom: 16)),
                    _field(EdgeInsets.zero),
                    const SizedBox(height: 12),
                    Flexible(child: ListView(shrinkWrap: true, children: _rows())),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      key: const Key('new-chat-page'),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                _title(24, const EdgeInsets.fromLTRB(24, 20, 12, 8)),
                _field(const EdgeInsets.fromLTRB(24, 8, 24, 12)),
                Expanded(
                  child: ListView(padding: const EdgeInsets.symmetric(horizontal: 24), children: _rows()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.bg, required this.child});
  final Color bg;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
    child: child,
  );
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.height, required this.avatar, required this.title, this.titleColor, this.onTap});
  final double height;
  final Widget avatar;
  final String title;
  final Color? titleColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: height,
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: titleColor),
            ),
          ),
        ],
      ),
    ),
  );
}
