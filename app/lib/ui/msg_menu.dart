import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Menu giữ lâu tin nhắn (S-06, docs/ui/Mobile-MsgMenu). Chỉ "Sao chép" có thật; phản ứng, Trả lời,
/// Chỉnh sửa, Xóa chưa có trong engine nên hiện mờ (xem docs/notes.md).
Future<void> showMsgMenu(BuildContext context, {required String text, required bool mine}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Đóng',
    barrierColor: const Color(0x8014171F),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, a1, a2) => MsgMenuView(
      text: text,
      mine: mine,
      onCopy: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (ctx.mounted) Navigator.of(ctx).pop();
      },
      onClose: () => Navigator.of(ctx).pop(),
    ),
  );
}

/// Phần giao diện thuần của menu (không nền mờ: nền do hộp thoại vẽ).
class MsgMenuView extends StatelessWidget {
  const MsgMenuView({super.key, required this.text, required this.mine, this.onCopy, this.onClose});

  final String text;
  final bool mine;
  final VoidCallback? onCopy, onClose;

  @override
  Widget build(BuildContext context) {
    const shadow = [BoxShadow(color: Color(0x2E14171F), blurRadius: 24, offset: Offset(0, 8))];
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 300, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: const BoxConstraints(maxWidth: 280),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: mine ? Ui.primary : Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(mine ? 18 : 4),
                        bottomRight: Radius.circular(mine ? 4 : 18),
                      ),
                    ),
                    child: Text(text, style: TextStyle(fontSize: 15, height: 1.4, color: mine ? Colors.white : Ui.text)),
                  ),
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: 0.45,
                    child: Container(
                      key: const Key('msg-reactions'),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), boxShadow: shadow),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Circle(Icons.thumb_up_outlined),
                          SizedBox(width: 6),
                          _Circle(Icons.favorite_border),
                          SizedBox(width: 6),
                          _Circle(Icons.sentiment_satisfied_outlined),
                          SizedBox(width: 6),
                          _Circle(Icons.add),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: 220,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: shadow),
                    child: Column(
                      children: [
                        const _Item(Icons.reply, 'Trả lời'),
                        _Item(Icons.copy_outlined, 'Sao chép', key: const Key('msg-copy'), onTap: onCopy),
                        if (mine) ...[
                          const _Item(Icons.edit_outlined, 'Chỉnh sửa'),
                          const Divider(height: 1, thickness: 1, color: Ui.border),
                          const _Item(Icons.delete_outline, 'Xóa', danger: true),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: const BoxDecoration(color: Ui.surface, shape: BoxShape.circle),
    child: Icon(icon, size: 22, color: Ui.text),
  );
}

class _Item extends StatelessWidget {
  const _Item(this.icon, this.label, {super.key, this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFB91C1C) : Ui.text;
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
