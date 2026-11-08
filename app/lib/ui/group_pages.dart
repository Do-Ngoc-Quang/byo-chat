import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../gen/chat/v1/common.pbenum.dart' show Role;
import '../gen/chat/v1/services.pbenum.dart';
import 'contact_dialog.dart';
import 'errors.dart';
import 'theme.dart';

/// Tạo nhóm (giao-thuc.md 6.2) theo docs/ui: tên nhóm + thành viên theo số điện thoại/email; mình là OWNER.
class GroupCreatePage extends StatefulWidget {
  const GroupCreatePage({super.key, required this.engine});

  final ChatEngine engine;

  @override
  State<GroupCreatePage> createState() => _GroupCreatePageState();
}

class _GroupCreatePageState extends State<GroupCreatePage> {
  final _title = TextEditingController();
  final _members = <(OtpChannel, String)>[];
  var _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final c = await askContact(context, title: 'Thêm thành viên', ok: 'Thêm');
    if (c != null) setState(() => _members.add((c.$1, c.$2.trim())));
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    ConvState? made;
    final nav = Navigator.of(context);
    final ok = await guarded(context, () async => made = await widget.engine.createGroup(_title.text, _members));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) nav.pop(made);
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('group-create-page'),
      title: 'Nhóm mới',
      subtitle: 'Một nhóm tối đa 256 thiết bị. Chỉ người đã đăng ký mới thêm được.',
      bottom: FilledButton(
        key: const Key('group-create'),
        onPressed: _busy || _members.isEmpty ? null : _create,
        child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Tạo nhóm'),
      ),
      children: [
        TextField(
          key: const Key('group-title'),
          controller: _title,
          enabled: !_busy,
          style: const TextStyle(fontSize: 16),
          decoration: const InputDecoration(hintText: 'Tên nhóm'),
        ),
        const SizedBox(height: 24),
        Text(
          'Thành viên (${_members.length})',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted),
        ),
        for (var i = 0; i < _members.length; i++)
          SizedBox(
            height: 56,
            child: Row(
              children: [
                Avatar(_members[i].$2),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_members[i].$2, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ),
                IconButton(
                  tooltip: 'Bỏ',
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => setState(() => _members.removeAt(i)),
                ),
              ],
            ),
          ),
        _ActionRow(key: const Key('group-add-member'), icon: Icons.person_add_alt, label: 'Thêm thành viên', onTap: _busy ? null : _add),
      ],
    );
  }
}

/// Hàng hành động có vòng tròn icon nền nhấn nhẹ (Thêm thành viên, Tạo nhóm mới trong thiết kế).
class _ActionRow extends StatelessWidget {
  const _ActionRow({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 56,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: Ui.accentBg, shape: BoxShape.circle),
            child: Icon(icon, color: Ui.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.primary),
          ),
        ],
      ),
    ),
  );
}

/// Thông tin nhóm (Mobile-Group.dc.html): avatar lớn, tên, số thành viên, danh sách thành viên đọc từ MLS,
/// thêm/gỡ/đổi vai trò (cần ADMIN/OWNER) và nút Rời nhóm.
class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({super.key, required this.engine, required this.conv});

  final ChatEngine engine;
  final ConvState conv;

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  late Future<Set<String>> _members = widget.engine.memberAccounts(widget.conv.hexId);

  void _reload() => setState(() => _members = widget.engine.memberAccounts(widget.conv.hexId));

  Future<void> _add() async {
    final c = await askContact(context, title: 'Thêm vào nhóm', ok: 'Thêm');
    if (c == null || !mounted) return;
    if (await guarded(context, () => widget.engine.addMember(widget.conv.hexId, c.$1, c.$2))) _reload();
  }

  Future<void> _remove(String account) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gỡ khỏi nhóm?'),
        content: Text('${widget.engine.displayName(account)} sẽ không đọc được tin mới của nhóm.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            key: const Key('confirm-remove'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
            child: const Text('Gỡ'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    if (await guarded(context, () => widget.engine.removeMember(widget.conv.hexId, unhex(account)))) _reload();
  }

  Future<void> _role(String account, {bool admin = false, bool owner = false}) async {
    final e = widget.engine, id = widget.conv.hexId;
    await guarded(
      context,
      () => owner ? e.transferOwnership(id, unhex(account)) : e.changeRole(id, unhex(account), admin ? Role.ROLE_ADMIN : Role.ROLE_MEMBER),
    );
    if (mounted) setState(() {});
  }

  Future<void> _leave() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rời nhóm?'),
        content: const Text('Quản trị viên đang trực tuyến sẽ xác nhận việc bạn rời nhóm. Sau đó bạn không đọc được tin mới.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            key: const Key('confirm-leave'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
            child: const Text('Rời nhóm'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await guarded(context, () => widget.engine.leaveGroup(widget.conv.hexId));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final me = hex(widget.engine.session.accountId);
    final conv = widget.conv;
    final canEdit = conv.admin && !conv.removed;
    return FutureBuilder<Set<String>>(
      future: _members,
      builder: (context, snap) {
        final list = (snap.data ?? <String>{}).toList()..sort();
        return ScreenScaffold(
          key: const Key('group-info-page'),
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Avatar(conv.title, size: 88),
              const SizedBox(height: 12),
              Text(conv.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                snap.hasData ? 'Nhóm · ${list.length} thành viên · tối đa 256 thiết bị' : 'Nhóm',
                style: const TextStyle(fontSize: 13, color: Ui.muted),
              ),
              const SizedBox(height: 24),
            ],
          ),
          bottom: !conv.removed && !conv.leaving
              ? OutlinedButton(
                  key: const Key('leave-group'),
                  onPressed: conv.owner ? null : _leave,
                  style: dangerOutline(),
                  child: Text(conv.owner ? 'Rời nhóm (chủ nhóm cần chuyển quyền trước)' : 'Rời nhóm'),
                )
              : null,
          children: [
            if (conv.removed)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('Bạn đã bị gỡ khỏi nhóm này. Chỉ đọc được lịch sử.', style: TextStyle(color: Ui.muted)),
              ),
            if (conv.leaving)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Row(
                  key: Key('leaving-note'),
                  children: [
                    Icon(Icons.hourglass_top, color: Ui.muted),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text('Đang chờ quản trị viên xác nhận bạn rời nhóm', style: TextStyle(color: Ui.muted)),
                    ),
                  ],
                ),
              ),
            const Text(
              'Thành viên',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted),
            ),
            if (!snap.hasData)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final a in list)
              SizedBox(
                key: Key('member-$a'),
                height: 56,
                child: Row(
                  children: [
                    Avatar(a == me ? 'Bạn' : widget.engine.displayName(a)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        a == me ? 'Bạn' : widget.engine.displayName(a),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (canEdit && a != me)
                      PopupMenuButton<String>(
                        key: Key('member-menu-$a'),
                        onSelected: (v) => switch (v) {
                          'remove' => _remove(a),
                          'transfer' => _role(a, owner: true),
                          _ => _role(a, admin: v == 'admin'),
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'remove', child: Text('Gỡ khỏi nhóm')),
                          const PopupMenuItem(value: 'admin', child: Text('Đặt làm quản trị viên')),
                          const PopupMenuItem(value: 'member', child: Text('Đặt làm thành viên')),
                          if (conv.owner) const PopupMenuItem(value: 'transfer', child: Text('Chuyển quyền chủ nhóm')),
                        ],
                      ),
                  ],
                ),
              ),
            if (canEdit) _ActionRow(key: const Key('add-to-group'), icon: Icons.person_add_alt, label: 'Thêm thành viên', onTap: _add),
          ],
        );
      },
    );
  }
}
