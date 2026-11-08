import 'package:flutter/material.dart';

import '../gen/chat/v1/services.pbenum.dart';
import 'theme.dart';

/// Hộp thoại nhập một liên hệ (số điện thoại hoặc email) theo phong cách docs/ui (Mobile-NewChat). Trả (kênh, đích)
/// hoặc null nếu hủy/để trống.
Future<(OtpChannel, String)?> askContact(BuildContext context, {required String title, required String ok}) async {
  final ctl = TextEditingController();
  var channel = OtpChannel.OTP_CHANNEL_SMS;
  final r = await showDialog<(OtpChannel, String)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final sms = channel == OtpChannel.OTP_CHANNEL_SMS;
        return AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('peer-field'),
                controller: ctl,
                autofocus: true,
                keyboardType: sms ? TextInputType.phone : TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: sms ? 'Nhập số điện thoại (+84...)' : 'Nhập email',
                  prefixIcon: Icon(sms ? Icons.phone_outlined : Icons.mail_outline, color: Ui.muted),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('peer-switch'),
                  onPressed: () => setState(() => channel = sms ? OtpChannel.OTP_CHANNEL_EMAIL : OtpChannel.OTP_CHANNEL_SMS),
                  child: Text(sms ? 'Dùng email' : 'Dùng số điện thoại'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
            FilledButton(
              key: const Key('peer-ok'),
              onPressed: () => Navigator.pop(ctx, (channel, ctl.text)),
              style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
              child: Text(ok),
            ),
          ],
        );
      },
    ),
  );
  ctl.dispose();
  if (r == null || r.$2.trim().isEmpty) return null;
  return r;
}
