import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../gen/chat/v1/services.pbenum.dart';
import 'contact_dialog.dart';
import 'errors.dart';

/// Tạo nhóm (giao-thuc.md 6.2): tên nhóm + danh sách thành viên theo số điện thoại/email; mình là OWNER.
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
    return Scaffold(
      key: const Key('group-create-page'),
      appBar: AppBar(title: const Text('Nhóm mới')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('group-title'),
            controller: _title,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Tên nhóm', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          Text('Thành viên (${_members.length})', style: Theme.of(context).textTheme.titleSmall),
          for (var i = 0; i < _members.length; i++)
            ListTile(
              dense: true,
              leading: Icon(_members[i].$1 == OtpChannel.OTP_CHANNEL_SMS ? Icons.phone : Icons.email),
              title: Text(_members[i].$2),
              trailing: IconButton(
                tooltip: 'Bỏ',
                icon: const Icon(Icons.close),
                onPressed: _busy ? null : () => setState(() => _members.removeAt(i)),
              ),
            ),
          TextButton.icon(
            key: const Key('group-add-member'),
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.person_add),
            label: const Text('Thêm thành viên'),
          ),
          const SizedBox(height: 8),
          Text('Một nhóm tối đa 256 thiết bị. Chỉ người đã đăng ký mới thêm được.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('group-create'),
            onPressed: _busy || _members.isEmpty ? null : _create,
            child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Tạo nhóm'),
          ),
        ],
      ),
    );
  }
}

/// Thông tin nhóm: thành viên (đọc từ trạng thái MLS), thêm/gỡ thành viên (cần ADMIN/OWNER).
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
        content: Text('Tài khoản ${account.substring(0, 8)}… sẽ không đọc được tin mới của nhóm.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(key: const Key('confirm-remove'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Gỡ')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    if (await guarded(context, () => widget.engine.removeMember(widget.conv.hexId, unhex(account)))) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final me = hex(widget.engine.session.accountId);
    final canEdit = widget.conv.admin && !widget.conv.removed;
    return Scaffold(
      key: const Key('group-info-page'),
      appBar: AppBar(title: Text(widget.conv.title)),
      body: FutureBuilder<Set<String>>(
        future: _members,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!.toList()..sort();
          return ListView(
            children: [
              if (widget.conv.removed)
                const MaterialBanner(content: Text('Bạn đã bị gỡ khỏi nhóm này. Chỉ đọc được lịch sử.'), actions: [SizedBox()]),
              ListTile(title: Text('${list.length} thành viên'), subtitle: const Text('Tối đa 256 thiết bị mỗi nhóm')),
              for (final a in list)
                ListTile(
                  key: Key('member-$a'),
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(a == me ? 'Bạn' : 'Tài khoản ${a.substring(0, 8)}…'),
                  trailing: canEdit && a != me
                      ? IconButton(
                          key: Key('remove-$a'),
                          tooltip: 'Gỡ khỏi nhóm',
                          icon: const Icon(Icons.person_remove),
                          onPressed: () => _remove(a),
                        )
                      : null,
                ),
              if (canEdit)
                ListTile(
                  key: const Key('add-to-group'),
                  leading: const Icon(Icons.person_add),
                  title: const Text('Thêm thành viên'),
                  onTap: _add,
                ),
            ],
          );
        },
      ),
    );
  }
}
