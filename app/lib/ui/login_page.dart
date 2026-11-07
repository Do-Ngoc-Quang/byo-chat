import 'package:flutter/material.dart';

import '../auth/login_controller.dart';
import '../gen/chat/v1/services.pbenum.dart';

/// Màn đăng nhập OTP (man-hinh.md): nhập số điện thoại hoặc email, rồi nhập mã.
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
        appBar: AppBar(title: const Text('Đăng nhập')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(16),
              children: [
                if (c.step == LoginStep.contact) ..._contactForm(),
                if (c.step == LoginStep.code) ..._codeForm(),
                if (c.step == LoginStep.registering) ..._registering(),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(c.error!, key: const Key('login-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _contactForm() => [
        SegmentedButton<OtpChannel>(
          segments: const [
            ButtonSegment(value: OtpChannel.OTP_CHANNEL_SMS, label: Text('Số điện thoại')),
            ButtonSegment(value: OtpChannel.OTP_CHANNEL_EMAIL, label: Text('Email')),
          ],
          selected: {_channel},
          onSelectionChanged: c.busy ? null : (s) => setState(() => _channel = s.first),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('contact-field'),
          controller: _contact,
          enabled: !c.busy,
          keyboardType: _channel == OtpChannel.OTP_CHANNEL_SMS ? TextInputType.phone : TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: _channel == OtpChannel.OTP_CHANNEL_SMS ? 'Số điện thoại (+84...)' : 'Email',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _request(),
        ),
        const SizedBox(height: 16),
        FilledButton(key: const Key('request-otp'), onPressed: c.busy ? null : _request, child: const Text('Gửi mã')),
      ];

  List<Widget> _codeForm() => [
        Text('Nhập mã gồm 6 chữ số đã gửi tới ${_contact.text.trim()}'),
        const SizedBox(height: 16),
        TextField(
          key: const Key('code-field'),
          controller: _code,
          enabled: !c.busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: 'Mã OTP', border: OutlineInputBorder()),
          onSubmitted: (_) => _verify(),
        ),
        FilledButton(key: const Key('verify-otp'), onPressed: c.busy ? null : _verify, child: const Text('Xác nhận')),
        TextButton(onPressed: c.busy ? null : c.backToContact, child: const Text('Đổi số hoặc email')),
      ];

  List<Widget> _registering() => [
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        const Center(child: Text('Đang tạo khóa mã hóa và đăng ký thiết bị...')),
        if (c.error != null && !c.busy)
          TextButton(key: const Key('retry-register'), onPressed: c.retryRegister, child: const Text('Thử lại')),
      ];

  void _request() => c.requestOtp(_channel, _contact.text);
  void _verify() => c.verifyCode(_code.text);
}
