import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import 'backup_pages.dart';
import 'desktop_shell.dart';
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
    if (MediaQuery.sizeOf(context).width >= desktopBreakpoint) {
      return SettingsDesktopView(
        accountCode: _id,
        onClose: () => Navigator.of(context).maybePop(),
        onBackup: () => open(BackupPage(engine: engine)),
        onDevices: () => open(DevicesPage(engine: engine)),
        devices: DevicesPage(engine: engine, embedded: true),
        onLogout: onLogout == null ? null : () => _logout(context),
      );
    }
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
          decoration: BoxDecoration(
            color: Ui.surfaceAlt,
            border: Border.all(color: Ui.border),
            borderRadius: BorderRadius.circular(16),
          ),
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
        SettingsRow(
          key: const Key('settings-backup'),
          icon: Icons.cloud_outlined,
          title: 'Sao lưu',
          subtitle: 'Recovery key và bản sao lưu',
          onTap: onBackup ?? () {},
        ),
        SettingsRow(
          key: const Key('settings-devices'),
          icon: Icons.desktop_windows_outlined,
          title: 'Thiết bị đã liên kết',
          onTap: onDevices ?? () {},
        ),
        if (onLogout != null)
          SettingsRow(key: const Key('settings-logout'), icon: Icons.logout, title: 'Đăng xuất', danger: true, onTap: onLogout!),
      ],
    );
  }
}

enum _Sec { account, notifications, devices }

/// Cài đặt Desktop (docs/ui/Desktop-Settings): thanh điều hướng 72 + danh sách mục 300 + nội dung (tối đa 760).
/// Thông báo/Quyền riêng tư chưa có dịch vụ nên hiện mờ, không giả chức năng.
class SettingsDesktopView extends StatefulWidget {
  const SettingsDesktopView({
    super.key,
    required this.accountCode,
    this.onClose,
    this.onBackup,
    this.onDevices,
    this.devices,
    this.onLogout,
  });

  final String accountCode;
  final VoidCallback? onClose, onLogout, onBackup, onDevices;

  /// Nội dung mục "Thiết bị đã liên kết" nhúng bên phải; null thì bấm mục sẽ mở trang riêng (onDevices).
  final Widget? devices;

  @override
  State<SettingsDesktopView> createState() => _SettingsDesktopViewState();
}

class _SettingsDesktopViewState extends State<SettingsDesktopView> {
  _Sec _sec = _Sec.account;

  Widget _item(String key, IconData icon, String label, {_Sec? sec, VoidCallback? onTap, bool dim = false}) {
    final sel = sec != null && _sec == sec;
    final w = InkWell(
      key: Key('sec-$key'),
      borderRadius: BorderRadius.circular(12),
      onTap: dim ? null : (onTap ?? () => setState(() => _sec = sec!)),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: sel ? Ui.accentBg : null, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Ui.text),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: sel ? FontWeight.w600 : FontWeight.w500, color: Ui.text, fontFamily: 'Inter'),
              ),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: dim ? Opacity(opacity: 0.45, child: w) : w,
    );
  }

  Widget _toggleRow(IconData icon, String title, [String? sub]) => Opacity(
    opacity: 0.45,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: Ui.accentBg, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: Ui.accentFg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Ui.text),
                  ),
                  if (sub != null) Text(sub, style: const TextStyle(fontSize: 13, color: Ui.muted)),
                ],
              ),
            ),
            Container(
              width: 48,
              height: 28,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Ui.primary, borderRadius: BorderRadius.circular(14)),
              child: Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  (String, List<Widget>) _content() => switch (_sec) {
    _Sec.account => (
      'Tài khoản',
      [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Ui.surfaceAlt,
            border: Border.all(color: Ui.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Avatar('Tôi', size: 56),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tài khoản của tôi', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  Text('Mã ${widget.accountCode}…', style: const TextStyle(fontSize: 13, color: Ui.muted)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (widget.onLogout != null)
          SettingsRow(key: const Key('settings-logout'), icon: Icons.logout, title: 'Đăng xuất', danger: true, onTap: widget.onLogout!),
      ],
    ),
    _Sec.notifications => (
      'Thông báo',
      [
        _toggleRow(Icons.notifications_none, 'Bật thông báo', 'Nhận thông báo khi có tin nhắn mới'),
        _toggleRow(Icons.visibility_outlined, 'Hiện nội dung tin nhắn', 'Tắt để chỉ hiện tên người gửi'),
        _toggleRow(Icons.call_outlined, 'Âm báo cuộc gọi'),
      ],
    ),
    _Sec.devices => ('Thiết bị đã liên kết', [widget.devices ?? const SizedBox.shrink()]),
  };

  @override
  Widget build(BuildContext context) {
    final (title, rows) = _content();
    return Scaffold(
      key: const Key('settings-desktop'),
      backgroundColor: Colors.white,
      body: Row(
        children: [
          DesktopRail(onSettings: () {}, settingsActive: true, onChat: widget.onClose),
          Container(
            width: 333,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Ui.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: Text('Cài đặt', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                ),
                _item('account', Icons.person_outline, 'Tài khoản', sec: _Sec.account),
                _item('notifications', Icons.notifications_none, 'Thông báo', sec: _Sec.notifications),
                _item('privacy', Icons.shield_outlined, 'Quyền riêng tư', dim: true),
                _item('backup', Icons.cloud_outlined, 'Sao lưu', onTap: widget.onBackup ?? () {}),
                _item(
                  'devices',
                  Icons.desktop_windows_outlined,
                  'Thiết bị đã liên kết',
                  sec: widget.devices != null ? _Sec.devices : null,
                  onTap: widget.devices != null ? null : (widget.onDevices ?? () {}),
                ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 872),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(56, 40, 56, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
                      SizedBox(height: _sec == _Sec.devices ? 18 : 24),
                      ...rows,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
