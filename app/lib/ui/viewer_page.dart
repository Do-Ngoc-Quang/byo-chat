import 'package:flutter/material.dart';

/// Trình xem ảnh và tệp (S-08, docs/ui/Mobile-Viewer). Chưa có media (giai đoạn 5, MediaService), nên
/// chưa có đường mở vào từ chat; vùng xem nhận widget nội dung và nút Lưu/Chia sẻ hiện mờ (docs/notes.md).
class ViewerView extends StatelessWidget {
  const ViewerView({super.key, required this.sender, required this.when, this.index = 1, this.total = 1, this.content, this.onClose});

  final String sender, when;
  final int index, total;
  final Widget? content;
  final VoidCallback? onClose;

  static const _bg = Color(0xFF0E1016);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('viewer-page'),
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('viewer-close'),
                    tooltip: 'Đóng',
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sender,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                        Text('$when · $index / $total', style: const TextStyle(fontSize: 12, color: Color(0xFFD5D8DE))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: 420,
                      width: double.infinity,
                      child:
                          content ??
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFFCBD5E1), Color(0xFF94A3B8)],
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
            const Opacity(
              opacity: 0.45,
              child: Padding(
                padding: EdgeInsets.fromLTRB(0, 16, 0, 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [_Action(Icons.file_download_outlined, 'Lưu'), SizedBox(width: 32), _Action(Icons.ios_share, 'Chia sẻ')],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, size: 24, color: Colors.white),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
    ],
  );
}
