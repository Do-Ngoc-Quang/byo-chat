import 'package:flutter/material.dart';

import 'theme.dart';

/// Thiết lập hồ sơ (S-03, docs/ui/Mobile-Profile): tên hiển thị và ảnh đại diện khi tạo tài khoản mới.
/// Chưa có ProfileService phía server nên chưa nối vào luồng đăng nhập; nút máy ảnh hiện mờ (docs/notes.md).
class ProfileSetupView extends StatefulWidget {
  const ProfileSetupView({super.key, this.initialName = '', this.onDone});

  final String initialName;
  final ValueChanged<String>? onDone;

  @override
  State<ProfileSetupView> createState() => _ProfileSetupViewState();
}

class _ProfileSetupViewState extends State<ProfileSetupView> {
  late final _name = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    // Chữ cái đầu của từ cuối (tên riêng), như thiết kế: "Nguyễn Bảo" -> B.
    final letter = name.isEmpty ? '?' : String.fromCharCode(name.split(RegExp(r'\s+')).last.runes.first).toUpperCase();
    return Scaffold(
      key: const Key('profile-setup'),
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Giới thiệu về bạn',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.3, height: 1.2, color: Ui.text),
              ),
              const SizedBox(height: 8),
              const Text('Thêm tên và ảnh để mọi người nhận ra bạn.', style: TextStyle(fontSize: 15, height: 1.5, color: Ui.muted)),
              const SizedBox(height: 32),
              Center(
                child: SizedBox(
                  width: 112,
                  height: 112,
                  child: Stack(
                    children: [
                      Container(
                        key: const Key('profile-avatar'),
                        width: 112,
                        height: 112,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: Ui.accentBg, shape: BoxShape.circle),
                        child: Text(
                          letter,
                          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w600, color: Ui.accentFg),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Opacity(
                          opacity: 0.45,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Ui.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                            child: const Icon(Icons.photo_camera_outlined, size: 18, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Thêm ảnh đại diện (không bắt buộc)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Ui.muted),
              ),
              const SizedBox(height: 28),
              const Text(
                'Tên hiển thị',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('profile-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 16, color: Ui.text),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Ui.radiusField),
                    borderSide: const BorderSide(color: Ui.fieldBorder, width: 2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Ui.radiusField),
                    borderSide: const BorderSide(color: Ui.primary, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Người khác sẽ thấy tên này khi nhắn tin với bạn.', style: TextStyle(fontSize: 13, color: Ui.muted)),
              const SizedBox(height: 28),
              FilledButton(
                key: const Key('profile-done'),
                onPressed: name.isEmpty || widget.onDone == null ? null : () => widget.onDone!(name),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(Ui.buttonHeight),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600),
                ),
                child: const Text('Hoàn tất'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
