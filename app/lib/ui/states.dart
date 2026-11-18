import 'package:flutter/material.dart';

import 'theme.dart';

/// Thẻ trạng thái trống/lỗi/đang tải dùng chung (S-18, docs/ui/Mobile-States): icon tròn 48,
/// tiêu đề 15/600, mô tả 13 muted, nút viền pill 40 tùy chọn.
class StateCard extends StatelessWidget {
  const StateCard({super.key, required this.icon, required this.title, required this.message, this.action, this.onAction});

  final IconData icon;
  final String title, message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Ui.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(color: Ui.accentBg, shape: BoxShape.circle),
            child: Icon(icon, size: 24, color: Ui.accentFg),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.text),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.5, color: Ui.muted),
          ),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('state-action'),
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                foregroundColor: Ui.text,
                side: const BorderSide(color: Ui.fieldBorder),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w600),
              ),
              child: Text(action!),
            ),
          ],
        ],
      ),
    );
  }
}

/// Dải cảnh báo vàng cao 36 (mất kết nối, đang chờ mạng).
class StatusBanner extends StatelessWidget {
  const StatusBanner(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    // Desktop (≥900): dải cao 40, chữ 14 (docs/ui/Desktop-States).
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Container(
    height: wide ? 40 : 36,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.wifi, size: 16, color: Color(0xFF78350F)),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(fontSize: wide ? 14 : 13, fontWeight: FontWeight.w500, color: const Color(0xFF78350F)),
        ),
      ],
    ),
  );
  }
}
