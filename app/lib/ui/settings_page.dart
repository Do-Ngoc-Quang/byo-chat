import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import 'backup_pages.dart';
import 'device_pages.dart';
import 'theme.dart';

/// Cài đặt (S-15, docs/ui/Mobile-Settings): thẻ tài khoản và các dòng có thật ở bản này:
/// Sao lưu, Thiết bị đã liên kết, Đăng xuất. Thông báo, quyền riêng tư, passkey, người đã chặn
/// chưa có dịch vụ phía server nên chưa hiện (xem docs/notes.md).
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.engine, this.onLogout});

  final ChatEngine engine;
  final VoidCallback? onLogout;

  String get _id => engine.session.accountId.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _logout(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đăng xuất?'),
        content: const Text('Thiết bị này sẽ xóa khóa và tin nhắn cục bộ. Cần liên kết hoặc khôi phục để dùng lại tài khoản.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            key: const Key('confirm-logout'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(minimumSize: const Size(110, 44), backgroundColor: Ui.danger),
            child: const Text('Đăng xuất'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    onLogout?.call();
  }

  @override
  Widget build(BuildContext context) {
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return SettingsView(
      accountCode: _id,
      onBackup: () => open(BackupPage(engine: engine)),
      onDevices: () => open(DevicesPage(engine: engine)),
      onLogout: onLogout == null ? null : () => _logout(context),
    );
  }
}

/// Phần giao diện thuần của Cài đặt (tách khỏi engine để chụp ảnh đối chiếu được).
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.accountCode, this.onBackup, this.onDevices, this.onLogout});

  final String accountCode;
  final VoidCallback? onBackup, onDevices, onLogout;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('settings-page'),
      title: 'Cài đặt',
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Ui.surfaceAlt, border: Border.all(color: Ui.border), borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              Avatar('Tôi', size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Tài khoản của tôi', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    Text('Mã $accountCode…', style: const TextStyle(fontSize: 13, color: Ui.muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SettingsRow(key: const Key('settings-backup'), icon: Icons.cloud_outlined, title: 'Sao lưu', subtitle: 'Recovery key và bản sao lưu', onTap: onBackup ?? () {}),
        SettingsRow(key: const Key('settings-devices'), icon: Icons.desktop_windows_outlined, title: 'Thiết bị đã liên kết', onTap: onDevices ?? () {}),
        if (onLogout != null) SettingsRow(key: const Key('settings-logout'), icon: Icons.logout, title: 'Đăng xuất', danger: true, onTap: onLogout!),
      ],
    );
  }
}
