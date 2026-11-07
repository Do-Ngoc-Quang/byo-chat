import 'package:flutter/material.dart';

import '../gen/chat/v1/services.pbenum.dart';

/// Hộp thoại nhập một liên hệ (số điện thoại hoặc email). Trả (kênh, đích) hoặc null nếu hủy/để trống.
Future<(OtpChannel, String)?> askContact(BuildContext context, {required String title, required String ok}) async {
  final ctl = TextEditingController();
  var channel = OtpChannel.OTP_CHANNEL_SMS;
  final r = await showDialog<(OtpChannel, String)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<OtpChannel>(
              segments: const [
                ButtonSegment(value: OtpChannel.OTP_CHANNEL_SMS, label: Text('Số điện thoại')),
                ButtonSegment(value: OtpChannel.OTP_CHANNEL_EMAIL, label: Text('Email')),
              ],
              selected: {channel},
              onSelectionChanged: (s) => setState(() => channel = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('peer-field'),
              controller: ctl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: channel == OtpChannel.OTP_CHANNEL_SMS ? 'Số điện thoại (+84...)' : 'Email',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          FilledButton(key: const Key('peer-ok'), onPressed: () => Navigator.pop(ctx, (channel, ctl.text)), child: Text(ok)),
        ],
      ),
    ),
  );
  ctl.dispose();
  if (r == null || r.$2.trim().isEmpty) return null;
  return r;
}
