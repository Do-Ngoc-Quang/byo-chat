import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/login_controller.dart';
import '../chat/backup.dart';
import '../chat/chat_engine.dart';
import 'errors.dart';

/// Bật/làm mới sao lưu (giao-thuc.md 6.14, ADR 0012). Recovery key chỉ hiện MỘT lần; app không lưu nó.
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.engine});

  final ChatEngine engine;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final _existingKey = TextEditingController();
  var _busy = false;
  String? _shownKey;
  var _saved = false;

  @override
  void dispose() {
    _existingKey.dispose();
    super.dispose();
  }

  Future<void> _backUp() async {
    setState(() {
      _busy = true;
      _shownKey = null;
      _saved = false;
    });
    String? shown;
    await guarded(context, () async {
      final svc = BackupService(api: widget.engine.api);
      final text = _existingKey.text.trim();
      final key = await svc.backUp(widget.engine.session, recoveryKey: text.isEmpty ? null : BackupService.parseKey(text));
      shown = text.isEmpty ? BackupService.formatKey(key) : null;
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _shownKey = shown;
      if (shown == null && _existingKey.text.isNotEmpty) _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('backup-page'),
      appBar: AppBar(title: const Text('Sao lưu')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Bản sao lưu gồm khóa tài khoản và lịch sử trò chuyện, được mã hóa bằng recovery key. Máy chủ không đọc được.'),
          const SizedBox(height: 8),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Nếu mất hết thiết bị VÀ quên recovery key, lịch sử trò chuyện sẽ mất vĩnh viễn. Không ai khôi phục giúp được.'),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('backup-key-field'),
            controller: _existingKey,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Recovery key đã có (để trống để tạo mới)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('backup-now'),
            onPressed: _busy ? null : _backUp,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Sao lưu ngay'),
          ),
          if (_shownKey != null) ...[
            const SizedBox(height: 24),
            Text('Recovery key của bạn', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            SelectableText(
              _shownKey!,
              key: const Key('recovery-key'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Chép'),
              onPressed: () => Clipboard.setData(ClipboardData(text: _shownKey!)),
            ),
            const Text('Hãy chép và cất ở nơi an toàn NGAY BÂY GIỜ. Màn hình này sẽ không hiện lại key.'),
          ],
          if (_saved)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('Đã sao lưu bằng recovery key bạn nhập.', key: Key('backup-saved')),
            ),
        ],
      ),
    );
  }
}

/// Khôi phục từ bản sao lưu sau khi OTP đúng cho tài khoản đã có (6.14).
class RestorePage extends StatefulWidget {
  const RestorePage({super.key, required this.login});

  final LoginController login;

  @override
  State<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends State<RestorePage> {
  final _key = TextEditingController();
  var _busy = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final l = widget.login;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    final ok = await guarded(context, () async {
      final s = await BackupService(api: l.api).restore(
        ticket: l.existingTicket!,
        accountId: l.existingAccountId!,
        recoveryKey: BackupService.parseKey(_key.text),
        openCore: l.openCore,
        platform: l.platform,
        store: l.store,
      );
      l.adopt(s);
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('restore-page'),
      appBar: AppBar(title: const Text('Khôi phục từ bản sao lưu')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Nhập recovery key bạn đã cất khi bật sao lưu. Lịch sử trò chuyện sẽ được khôi phục; tin cũ nằm ngoài lịch sử sao lưu không đọc lại được.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('restore-key-field'),
            controller: _key,
            enabled: !_busy,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Recovery key (64 ký tự)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('restore-go'),
            onPressed: _busy ? null : _restore,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Khôi phục'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Sau khi khôi phục, hãy vào Thiết bị của tôi và thu hồi thiết bị cũ đã mất.'),
          ),
        ],
      ),
    );
  }
}
