import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/link_controller.dart';
import '../auth/login_controller.dart';
import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/services.pb.dart';
import 'errors.dart';

/// Danh sách thiết bị của tài khoản (giao-thuc.md 6.5, 6.6): thêm thiết bị mới, thu hồi thiết bị.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.engine});

  final ChatEngine engine;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  late Future<List<DeviceInfo>> _devices = widget.engine.listDevices();

  void _reload() => setState(() => _devices = widget.engine.listDevices());

  Future<void> _revoke(DeviceInfo d) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thu hồi thiết bị?'),
        content: Text('"${d.deviceName}" sẽ bị đăng xuất và gỡ khỏi mọi cuộc trò chuyện. Thao tác này không hoàn tác được.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(key: const Key('confirm-revoke'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Thu hồi')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    var removed = 0;
    final ok = await guarded(context, () async => removed = await widget.engine.revokeDevice(unhex(hex(d.deviceId))));
    if (ok) messenger.showSnackBar(SnackBar(content: Text('Đã thu hồi; đã gỡ khỏi $removed cuộc trò chuyện.')));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final me = hex(widget.engine.session.deviceId);
    return Scaffold(
      key: const Key('devices-page'),
      appBar: AppBar(title: const Text('Thiết bị của tôi')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-device'),
        icon: const Icon(Icons.add_to_home_screen),
        label: const Text('Thêm thiết bị'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LinkApprovePage(engine: widget.engine))),
      ),
      body: FutureBuilder<List<DeviceInfo>>(
        future: _devices,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Không tải được danh sách: ${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView(
            children: [
              for (final d in snap.data!)
                ListTile(
                  key: Key('device-${hex(d.deviceId)}'),
                  leading: Icon(_icon(d.platform)),
                  title: Text(d.deviceName.isEmpty ? 'Thiết bị' : d.deviceName),
                  subtitle: Text(
                    hex(d.deviceId) == me
                        ? 'Thiết bị này'
                        : d.revoked
                        ? 'Đã thu hồi'
                        : 'Đăng ký ${_date(d.createdMs.toInt())}',
                  ),
                  trailing: hex(d.deviceId) == me || d.revoked
                      ? null
                      : IconButton(
                          key: Key('revoke-${hex(d.deviceId)}'),
                          tooltip: 'Thu hồi',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _revoke(d),
                        ),
                ),
            ],
          );
        },
      ),
    );
  }

  static IconData _icon(Platform p) => switch (p) {
    Platform.PLATFORM_ANDROID || Platform.PLATFORM_IOS => Icons.smartphone,
    Platform.PLATFORM_WEB => Icons.language,
    _ => Icons.computer,
  };

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}

/// Thiết bị CŨ duyệt thiết bị mới (6.5 bước 2): dán mã liên kết hiển thị ở máy mới, so khớp mã 6 số, xác nhận.
/// (Quét QR bằng camera chưa có: cần plugin camera và thiết bị thật; hiện dán chuỗi mã.)
class LinkApprovePage extends StatefulWidget {
  const LinkApprovePage({super.key, required this.engine});

  final ChatEngine engine;

  @override
  State<LinkApprovePage> createState() => _LinkApprovePageState();
}

class _LinkApprovePageState extends State<LinkApprovePage> {
  final _code = TextEditingController();
  LinkOffer? _offer;
  var _busy = false;
  var _done = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _read() {
    try {
      setState(() => _offer = LinkOffer.decode(_code.text));
    } on Object {
      setState(() => _offer = null);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mã liên kết không hợp lệ.')));
    }
  }

  Future<void> _approve() async {
    setState(() => _busy = true);
    final ok = await guarded(context, () => widget.engine.approveLink(_offer!));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final o = _offer;
    return Scaffold(
      key: const Key('link-approve-page'),
      appBar: AppBar(title: const Text('Thêm thiết bị mới')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Trên thiết bị mới, chọn "Đăng nhập bằng thiết bị khác" rồi dán mã hiển thị ở đó vào đây.'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('link-code-field'),
            controller: _code,
            enabled: !_busy && !_done,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'Mã liên kết',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Dán',
                icon: const Icon(Icons.paste),
                onPressed: () async {
                  final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                  if (t != null) _code.text = t;
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(key: const Key('link-read'), onPressed: _busy || _done ? null : _read, child: const Text('Đọc mã')),
          if (o != null) ...[
            const SizedBox(height: 24),
            Text('Mã xác nhận', style: Theme.of(context).textTheme.titleSmall),
            Text(o.shortCode, key: const Key('link-short-code'), style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 8),
            const Text(
              'Chỉ xác nhận nếu mã này TRÙNG với mã đang hiện trên thiết bị mới. Nếu không trùng, có người khác đang cố vào tài khoản của bạn.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('link-approve'),
              onPressed: _busy || _done ? null : _approve,
              child: const Text('Mã trùng, cho phép thiết bị này'),
            ),
          ],
          if (_done)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('Đã duyệt. Thiết bị mới đang hoàn tất đăng nhập.', key: Key('link-done')),
            ),
        ],
      ),
    );
  }
}

/// Thiết bị MỚI (6.5 bước 1, 3-5): hiện mã QR + chuỗi mã + mã 6 số, chờ thiết bị cũ duyệt, rồi đăng ký và vào nhóm.
class LinkNewDevicePage extends StatefulWidget {
  const LinkNewDevicePage({super.key, required this.login});

  final LoginController login;

  @override
  State<LinkNewDevicePage> createState() => _LinkNewDevicePageState();
}

class _LinkNewDevicePageState extends State<LinkNewDevicePage> {
  late final LinkController _link = LinkController(
    api: widget.login.api,
    openCore: widget.login.openCore,
    store: widget.login.store,
    platform: widget.login.platform,
  );
  LinkOffer? _offer;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  Future<void> _begin() async {
    setState(() {
      _offer = null;
      _error = null;
    });
    try {
      final offer = await _link.start();
      if (!mounted) return;
      setState(() => _offer = offer);
      final s = await _link.complete();
      if (!mounted) return;
      if (s != null) {
        widget.login.adopt(s);
        Navigator.of(context).pop();
      } else {
        setState(() => _error = _link.error ?? 'Liên kết không thành công.');
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Không bắt đầu được liên kết: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _offer;
    return Scaffold(
      key: const Key('link-new-page'),
      appBar: AppBar(title: const Text('Đăng nhập bằng thiết bị khác')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (o == null && _error == null) const Center(child: CircularProgressIndicator()),
          if (o != null) ...[
            const Text('Mở BYO Chat trên thiết bị đã đăng nhập: Thiết bị của tôi > Thêm thiết bị, rồi nhập mã dưới đây.'),
            const SizedBox(height: 16),
            Center(
              child: QrImageView(data: o.encode(), size: 220, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 16),
            Text('Mã xác nhận', style: Theme.of(context).textTheme.titleSmall),
            Text(o.shortCode, key: const Key('new-short-code'), style: Theme.of(context).textTheme.displaySmall),
            const Text('Mã này phải TRÙNG với mã hiện trên thiết bị đã đăng nhập.'),
            const SizedBox(height: 12),
            SelectableText(o.encode(), key: const Key('link-offer-text'), style: Theme.of(context).textTheme.bodySmall),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Chép mã'),
              onPressed: () => Clipboard.setData(ClipboardData(text: o.encode())),
            ),
            if (_error == null) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Đang chờ thiết bị kia xác nhận…')),
          ],
          if (_error != null) ...[
            Text(
              _error!,
              key: const Key('link-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(key: const Key('link-retry'), onPressed: _begin, child: const Text('Thử lại')),
          ],
        ],
      ),
    );
  }
}
