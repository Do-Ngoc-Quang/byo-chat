import 'package:flutter/material.dart';

import '../auth/login_controller.dart';
import '../gen/chat/v1/services.pbenum.dart';
import 'backup_pages.dart';
import 'device_pages.dart';
import 'theme.dart';

/// Màn đăng nhập OTP theo docs/ui (Mobile-Login, Mobile-Otp): nhập số điện thoại hoặc email, rồi nhập mã.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});

  final LoginController controller;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _contact = TextEditingController();
  final _code = TextEditingController();
  OtpChannel _channel = OtpChannel.OTP_CHANNEL_SMS;

  LoginController get c => widget.controller;

  @override
  void dispose() {
    _contact.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                padding: EdgeInsets.fromLTRB(24, c.step == LoginStep.code ? 8 : 96, 24, 24),
                children: [
                  if (c.step == LoginStep.code)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        key: const Key('back-to-contact'),
                        tooltip: 'Quay lại',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: c.busy ? null : c.backToContact,
                      ),
                    ),
                  const _LogoTile(),
                  const SizedBox(height: 24),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        c.error!,
                        key: const Key('login-error'),
                        style: const TextStyle(color: Ui.danger, fontSize: 14),
                      ),
                    ),
                  if (c.step == LoginStep.contact) ..._contactForm(),
                  if (c.step == LoginStep.code) ..._codeForm(),
                  if (c.step == LoginStep.registering) ..._registering(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(String h, String sub) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(h, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
      const SizedBox(height: 8),
      Text(sub, style: const TextStyle(fontSize: 15, color: Ui.muted, height: 1.4)),
      const SizedBox(height: 24),
    ],
  );

  List<Widget> _contactForm() {
    final sms = _channel == OtpChannel.OTP_CHANNEL_SMS;
    return [
      _title('Chào mừng đến Chat', 'Nhập ${sms ? 'số điện thoại' : 'email'} để bắt đầu. Chúng tôi sẽ gửi mã xác nhận.'),
      TextField(
        key: const Key('contact-field'),
        controller: _contact,
        enabled: !c.busy,
        autofocus: true,
        keyboardType: sms ? TextInputType.phone : TextInputType.emailAddress,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(hintText: sms ? '+84 912 345 678' : 'ten@example.com'),
        onSubmitted: (_) => _request(),
      ),
      const SizedBox(height: 16),
      FilledButton(key: const Key('request-otp'), onPressed: c.busy ? null : _request, child: const Text('Tiếp tục')),
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          key: const Key('switch-channel'),
          onPressed: c.busy ? null : () => setState(() => _channel = sms ? OtpChannel.OTP_CHANNEL_EMAIL : OtpChannel.OTP_CHANNEL_SMS),
          child: Text(sms ? 'Dùng email' : 'Dùng số điện thoại'),
        ),
      ),
      if (c.existing) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('open-restore'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RestorePage(login: c))),
          child: const Text('Khôi phục từ bản sao lưu'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('open-reset'),
          onPressed: c.busy ? null : _confirmReset,
          style: TextButton.styleFrom(foregroundColor: Ui.danger),
          child: const Text('Không có bản sao lưu: bắt đầu lại'),
        ),
      ],
      const SizedBox(height: 8),
      OutlinedButton(
        key: const Key('open-link'),
        onPressed: c.busy ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LinkNewDevicePage(login: c))),
        child: const Text('Đăng nhập bằng thiết bị khác của tôi'),
      ),
      const SizedBox(height: 32),
      const Text(
        'Bằng việc tiếp tục, bạn đồng ý với Điều khoản sử dụng và Chính sách quyền riêng tư.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: Ui.muted, height: 1.4),
      ),
    ];
  }

  List<Widget> _codeForm() => [
    _title('Nhập mã xác nhận', 'Mã gồm 6 số đã được gửi tới ${_contact.text.trim()}.'),
    _OtpBoxes(controller: _code, enabled: !c.busy, onDone: _verify, onChanged: () => setState(() {})),
    const SizedBox(height: 24),
    FilledButton(key: const Key('verify-otp'), onPressed: c.busy ? null : _verify, child: const Text('Xác nhận')),
    const SizedBox(height: 8),
    Center(
      child: TextButton(onPressed: c.busy ? null : c.backToContact, child: const Text('Đổi số hoặc email')),
    ),
  ];

  List<Widget> _registering() => [
    const Center(child: CircularProgressIndicator()),
    const SizedBox(height: 16),
    const Center(
      child: Text('Đang tạo khóa mã hóa và đăng ký thiết bị...', style: TextStyle(color: Ui.muted)),
    ),
    if (c.error != null && !c.busy) TextButton(key: const Key('retry-register'), onPressed: c.retryRegister, child: const Text('Thử lại')),
  ];

  /// Khôi phục không có bản sao lưu (6.14): khóa danh tính mới, mất toàn bộ tin cũ, thiết bị cũ bị thu hồi.
  Future<void> _confirmReset() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bắt đầu lại không có bản sao lưu?'),
        content: const Text(
          'Mọi tin nhắn cũ sẽ mất vĩnh viễn và mọi thiết bị cũ của tài khoản bị thu hồi. Bạn vẫn giữ tài khoản và vào lại được các cuộc trò chuyện.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            key: const Key('confirm-reset'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(minimumSize: const Size(110, 44), backgroundColor: Ui.danger),
            child: const Text('Bắt đầu lại'),
          ),
        ],
      ),
    );
    if (yes == true) await c.resetIdentity();
  }

  void _request() => c.requestOtp(_channel, _contact.text);
  void _verify() => c.verifyCode(_code.text);
}

/// Ô logo 52px bo 14 nền nhấn (thiết kế Login/Otp).
class _LogoTile extends StatelessWidget {
  const _LogoTile();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(color: Ui.primary, borderRadius: BorderRadius.circular(14)),
      child: const Icon(Icons.lock_outline, color: Colors.white, size: 26),
    ),
  );
}

/// Sáu ô mã OTP. Một TextField trong suốt phủ lên các ô để nhận bàn phím và dán mã.
class _OtpBoxes extends StatelessWidget {
  const _OtpBoxes({required this.controller, required this.enabled, required this.onDone, required this.onChanged});

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onDone, onChanged;

  @override
  Widget build(BuildContext context) {
    final t = controller.text;
    return Stack(
      children: [
        Row(
          children: [
            for (var i = 0; i < 6; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i < t.length ? Ui.accentBg : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: i == t.length ? Ui.primary : Ui.border, width: i == t.length ? 2 : 1),
                  ),
                  child: Text(
                    i < t.length ? t[i] : '',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: Ui.accentFg),
                  ),
                ),
              ),
            ],
          ],
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              key: const Key('code-field'),
              controller: controller,
              enabled: enabled,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onDone(),
            ),
          ),
        ),
      ],
    );
  }
}
