import 'package:flutter/material.dart';

import '../chat/local_doc.dart';
import 'theme.dart';

/// Hồ sơ liên hệ (S-11, docs/ui/Mobile-Contact). Chưa có ProfileService/BlockService phía server,
/// nên các tính năng đó hiện mờ kèm ghi chú (xem docs/notes.md).
class ContactPage extends StatelessWidget {
  const ContactPage({super.key, required this.conv});

  final ConvState conv;

  @override
  Widget build(BuildContext context) => ContactView(name: conv.title, onBack: () => Navigator.of(context).pop());
}

/// Phần giao diện thuần của Hồ sơ liên hệ.
class ContactView extends StatelessWidget {
  const ContactView({super.key, required this.name, this.onBack});

  final String name;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('contact-page'),
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const Key('contact-back'),
                  tooltip: 'Quay lại',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                ),
              ),
              Expanded(child: ListView(children: _contactChildren(name))),
              const _BlockButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class InfoTile extends StatelessWidget {
  const InfoTile(this.icon, this.label, {super.key});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Opacity(
      opacity: 0.45,
      child: Container(
        height: 68,
        decoration: BoxDecoration(color: Ui.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: Ui.text),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Ui.text),
            ),
          ],
        ),
      ),
    ),
  );
}

List<Widget> _contactChildren(String name) => [
  const SizedBox(height: 4),
  Center(child: Avatar(name, size: 88)),
  const SizedBox(height: 14),
  Text(
    name,
    textAlign: TextAlign.center,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Ui.text),
  ),
  const SizedBox(height: 22),
  const Row(
    children: [
      InfoTile(Icons.videocam_outlined, 'Gọi video'),
      SizedBox(width: 10),
      InfoTile(Icons.notifications_off_outlined, 'Tắt tiếng'),
      SizedBox(width: 10),
      InfoTile(Icons.search, 'Tìm kiếm'),
    ],
  ),
  const SizedBox(height: 26),
  const Text(
    'Ảnh và tệp',
    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.muted),
  ),
  const SizedBox(height: 12),
  Container(
    key: const Key('contact-media-empty'),
    height: 96,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: Ui.surfaceAlt, borderRadius: BorderRadius.circular(8)),
    child: const Text('Chưa có ảnh hay tệp chung', style: TextStyle(fontSize: 14, color: Ui.muted)),
  ),
];

class _BlockButton extends StatelessWidget {
  const _BlockButton();

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: 0.45,
    child: Container(
      key: const Key('contact-block'),
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.block, size: 18, color: Color(0xFFB91C1C)),
          SizedBox(width: 8),
          Text(
            'Chặn người dùng',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFB91C1C)),
          ),
        ],
      ),
    ),
  );
}

/// Bảng hồ sơ liên hệ bên phải khung chat Desktop (docs/ui/Desktop-Contact): rộng 340, viền trái, đệm 24.
class ContactPanel extends StatelessWidget {
  const ContactPanel({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('contact-panel'),
    width: 340,
    padding: const EdgeInsets.all(24),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(left: BorderSide(color: Ui.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: ListView(children: _contactChildren(name))),
        const _BlockButton(),
      ],
    ),
  );
}
