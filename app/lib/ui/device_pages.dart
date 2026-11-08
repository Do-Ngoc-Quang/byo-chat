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
import 'theme.dart';

/// Thiết bị đã liên kết (Mobile-Devices.dc.html): thẻ từng thiết bị, "Thiết bị này", nút Gỡ, nút Liên kết thiết bị mới.
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
          FilledButton(
            key: const Key('confirm-revoke'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
            child: const Text('Thu hồi'),
          ),
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
    return ScreenScaffold(
      key: const Key('devices-page'),
      title: 'Thiết bị đã liên kết',
      subtitle: 'Gỡ những thiết bị bạn không còn sử dụng.',
      bottom: FilledButton(
        key: const Key('add-device'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LinkApprovePage(engine: widget.engine))),
        child: const Text('Liên kết thiết bị mới'),
      ),
      children: [
        FutureBuilder<List<DeviceInfo>>(
          future: _devices,
          builder: (context, snap) {
            if (snap.hasError) return Text('Không tải được danh sách: ${snap.error}', style: const TextStyle(color: Ui.danger));
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              children: [
                for (final d in snap.data!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InfoCard(
                      key: Key('device-${hex(d.deviceId)}'),
                      icon: _icon(d.platform),
                      title: d.deviceName.isEmpty ? 'Thiết bị' : d.deviceName,
                      subtitle: d.revoked ? 'Đã thu hồi' : 'Đăng ký ${_date(d.createdMs.toInt())}',
                      trailing: hex(d.deviceId) == me
                          ? const _Pill('Thiết bị này')
                          : d.revoked
                          ? null
                          : OutlinedButton(
                              key: Key('revoke-${hex(d.deviceId)}'),
                              onPressed: () => _revoke(d),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(56, 36),
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                foregroundColor: const Color(0xFFB91C1C),
                                side: const BorderSide(color: Ui.fieldBorder),
                                backgroundColor: Colors.white,
                                shape: const StadiumBorder(),
                                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                              child: const Text('Gỡ'),
                            ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
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

/// Nhãn xanh lục "Thiết bị này" (nền #DCFCE7, chữ #166534).
class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(12)),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF166534)),
    ),
  );
}

/// Thiết bị CŨ duyệt thiết bị mới (6.5 bước 2, Mobile-Link.dc.html): dán mã liên kết hiển thị ở máy mới, so khớp mã 6 số,
/// phê duyệt. (Quét QR bằng camera chưa có: cần plugin camera và thiết bị thật; hiện dán chuỗi mã.)
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
    final locked = _busy || _done;
    return ScreenScaffold(
      key: const Key('link-approve-page'),
      title: 'Liên kết thiết bị mới',
      subtitle: 'Trên thiết bị mới, chọn "Đăng nhập bằng thiết bị khác" rồi dán mã hiển thị ở đó vào đây.',
      bottom: o == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(key: const Key('link-approve'), onPressed: locked ? null : _approve, child: const Text('Phê duyệt thiết bị')),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: locked ? null : () => Navigator.of(context).maybePop(), child: const Text('Từ chối')),
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Chỉ phê duyệt nếu chính bạn đang đăng nhập. Thiết bị mới sẽ đọc được tin nhắn mới, không đọc được tin cũ.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Ui.muted, height: 1.4),
                  ),
                ),
              ],
            ),
      children: [
        TextField(
          key: const Key('link-code-field'),
          controller: _code,
          enabled: !locked,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: 'Mã liên kết',
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
        const SizedBox(height: 12),
        OutlinedButton(key: const Key('link-read'), onPressed: locked ? null : _read, child: const Text('Đọc mã')),
        if (o != null) ...[
          const SizedBox(height: 24),
          const Text('Mã xác nhận trên thiết bị mới phải khớp:', style: TextStyle(fontSize: 13, color: Ui.muted)),
          const SizedBox(height: 8),
          CodeBoxes(o.shortCode, key: const Key('link-short-code')),
          const SizedBox(height: 8),
          const Text(
            'Nếu không trùng, có người khác đang cố vào tài khoản của bạn: đừng phê duyệt.',
            style: TextStyle(fontSize: 13, color: Ui.muted, height: 1.4),
          ),
        ],
        if (_done)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Đã duyệt. Thiết bị mới đang hoàn tất đăng nhập.', key: Key('link-done')),
          ),
      ],
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
    return ScreenScaffold(
      key: const Key('link-new-page'),
      title: 'Đăng nhập bằng thiết bị khác',
      subtitle: 'Mở BYO Chat trên thiết bị đã đăng nhập: Thiết bị của tôi > Liên kết thiết bị mới, rồi nhập mã dưới đây.',
      children: [
        if (o == null && _error == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (o != null) ...[
          Container(
            height: 280,
            decoration: BoxDecoration(color: Ui.text, borderRadius: BorderRadius.circular(20)),
            alignment: Alignment.center,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(data: o.encode(), size: 220, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Mã xác nhận (phải khớp với thiết bị đã đăng nhập):', style: TextStyle(fontSize: 13, color: Ui.muted)),
          const SizedBox(height: 8),
          CodeBoxes(o.shortCode, key: const Key('new-short-code')),
          const SizedBox(height: 16),
          SelectableText(
            o.encode(),
            key: const Key('link-offer-text'),
            style: const TextStyle(fontSize: 12, color: Ui.muted),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Chép mã'),
            onPressed: () => Clipboard.setData(ClipboardData(text: o.encode())),
          ),
          if (_error == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Đang chờ phê duyệt…', style: TextStyle(color: Ui.muted)),
            ),
        ],
        if (_error != null) ...[
          Text(
            _error!,
            key: const Key('link-error'),
            style: const TextStyle(color: Ui.danger),
          ),
          TextButton(key: const Key('link-retry'), onPressed: _begin, child: const Text('Thử lại')),
        ],
      ],
    );
  }
}
