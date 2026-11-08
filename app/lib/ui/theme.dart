// Theme theo docs/ui (token trích từ các tệp *.dc.html): Inter, nền trắng, chữ #14171F, nhấn #2563EB.
import 'package:flutter/material.dart';

OutlineInputBorder _outline(BorderSide side) => OutlineInputBorder(borderRadius: BorderRadius.circular(Ui.radiusField), borderSide: side);

class Ui {
  static const text = Color(0xFF14171F);
  static const muted = Color(0xFF5B6270);
  static const border = Color(0xFFE4E6EB);
  static const surface = Color(0xFFF0F2F5); // nút tròn, ô nhập
  static const surfaceAlt = Color(0xFFF7F8FA);
  static const primary = Color(0xFF2563EB);
  static const bubbleMineBg = Color(0xFF2563EB);
  static const bubbleTheirsBg = Color(0xFFF0F2F5);
  static const accentBg = Color(0xFFEEF2FF); // vùng nhấn nhẹ
  static const accentFg = Color(0xFF3730A3);
  static const avatarBg = Color(0xFFDBEAFE);
  static const avatarFg = Color(0xFF1E40AF);
  static const danger = Color(0xFFDC2626);

  /// Vùng chạm tối thiểu 44px của thiết kế.
  static const tap = 44.0;
  static const buttonHeight = 52.0;
  static const fieldBorder = Color(0xFFD5D8DE);
  static const radiusField = 14.0;
  static const radiusBubble = 18.0;

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.light).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: text,
      onSurfaceVariant: muted,
      outlineVariant: border,
      error: danger,
      primaryContainer: accentBg,
      onPrimaryContainer: accentFg,
      surfaceContainerHighest: surface,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Inter');
    return base.copyWith(
      scaffoldBackgroundColor: Colors.white,
      dividerColor: border,
      dividerTheme: const DividerThemeData(color: border, space: 1, thickness: 1),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: Border(bottom: BorderSide(color: border)),
        titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600, color: text),
      ),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text, fontFamily: 'Inter'),
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        border: _outline(const BorderSide(color: fieldBorder)),
        enabledBorder: _outline(const BorderSide(color: fieldBorder)),
        focusedBorder: _outline(const BorderSide(color: primary, width: 2)),
        errorBorder: _outline(const BorderSide(color: danger)),
        focusedErrorBorder: _outline(const BorderSide(color: danger, width: 2)),
        hintStyle: const TextStyle(color: muted),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(buttonHeight),
          backgroundColor: primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: surface,
          disabledForegroundColor: muted,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(buttonHeight),
          foregroundColor: text,
          side: const BorderSide(color: fieldBorder),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary, minimumSize: const Size(tap, tap)),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 10, iconColor: muted),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusField)),
      ),
    );
  }
}

/// Avatar tròn chữ cái đầu. Bảng màu lấy từ docs/ui (xanh, vàng, lục, hồng, xám), chọn theo nội dung nhãn.
class Avatar extends StatelessWidget {
  const Avatar(this.label, {super.key, this.size = 40});
  final String label;
  final double size;

  static const _palette = [
    (Color(0xFFDBEAFE), Color(0xFF1E40AF)),
    (Color(0xFFFDE68A), Color(0xFF78350F)),
    (Color(0xFFD1FAE5), Color(0xFF065F46)),
    (Color(0xFFFCE7F3), Color(0xFF9D174D)),
    (Color(0xFFE5E7EB), Color(0xFF374151)),
  ];

  static String initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final a = String.fromCharCode(parts.first.runes.first);
    final b = parts.length > 1 ? String.fromCharCode(parts.last.runes.first) : '';
    return (a + b).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _palette[label.runes.fold<int>(0, (a, r) => (a * 31 + r) & 0xffff) % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        initials(label),
        style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: size * 0.34),
      ),
    );
  }
}

/// Giờ rút gọn của danh sách hội thoại: hôm nay HH:mm, hôm qua, trong tuần là thứ, còn lại dd/MM.
String shortTime(int ms, {DateTime? now}) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  if (days <= 0) return '${two(t.hour)}:${two(t.minute)}';
  if (days == 1) return 'Hôm qua';
  if (days < 7) return const ['Thứ hai', 'Thứ ba', 'Thứ tư', 'Thứ năm', 'Thứ sáu', 'Thứ bảy', 'Chủ nhật'][t.weekday - 1];
  return '${two(t.day)}/${two(t.month)}';
}

/// Khung màn phụ theo docs/ui (Group/Devices/Link...): nút quay lại 44px, tiêu đề 28/600, mô tả 15 xám, nội dung cuộn,
/// và vùng nút cố định ở đáy (24px hai bên, 32px dưới). `key` đặt lên Scaffold để test tìm màn.
class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({super.key, this.title, this.subtitle, this.header, required this.children, this.bottom, this.titleSize = 28});

  final String? title, subtitle;

  /// Thay cho khối tiêu đề mặc định (vd. avatar lớn của thông tin nhóm).
  final Widget? header;
  final List<Widget> children;
  final Widget? bottom;
  final double titleSize;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            children: [
              if (Navigator.of(context).canPop())
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 12, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Quay lại',
                      icon: const Icon(Icons.arrow_back),
                      style: IconButton.styleFrom(fixedSize: const Size.square(Ui.tap)),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  children: [
                    ?header,
                    if (header == null && title != null) ...[
                      Text(
                        title!,
                        style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w600, letterSpacing: -0.3),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 8),
                        Text(subtitle!, style: const TextStyle(fontSize: 15, color: Ui.muted, height: 1.4)),
                      ],
                      const SizedBox(height: 24),
                    ],
                    ...children,
                  ],
                ),
              ),
              if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 32), child: bottom),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Thẻ thông tin (thiết bị, yêu cầu liên kết): nền #F7F8FA, viền #E4E6EB, bo 16.
class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.icon, required this.title, required this.subtitle, this.trailing});

  final IconData icon;
  final String title, subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Ui.surfaceAlt,
      border: Border.all(color: Ui.border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Container(
          width: Ui.tap,
          height: Ui.tap,
          decoration: BoxDecoration(color: Ui.accentBg, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: Ui.accentFg),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 13, color: Ui.muted)),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Nhóm sáu ô số (mã xác nhận liên kết): nền #EEF2FF, chữ #3730A3.
class CodeBoxes extends StatelessWidget {
  const CodeBoxes(this.code, {super.key});
  final String code;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < code.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Ui.accentBg, borderRadius: BorderRadius.circular(12)),
            child: Text(
              code[i],
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Ui.accentFg),
            ),
          ),
        ),
      ],
    ],
  );
}

/// Nút viền đỏ (Rời nhóm, Gỡ) theo thiết kế.
ButtonStyle dangerOutline({double height = 48}) => OutlinedButton.styleFrom(
  minimumSize: Size.fromHeight(height),
  foregroundColor: const Color(0xFFB91C1C),
  side: const BorderSide(color: Color(0xFFFCA5A5)),
  shape: const StadiumBorder(),
  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
);
