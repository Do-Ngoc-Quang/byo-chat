import 'package:flutter/material.dart';

import '../auth/login_controller.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Màn tạm sau đăng nhập: xác nhận thiết bị đã đăng ký. Danh sách chat làm ở bước kế tiếp.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.session, this.onLogout});

  final Session session;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BYO Chat'),
        actions: [
          if (onLogout != null) IconButton(key: const Key('logout'), tooltip: 'Đăng xuất', icon: const Icon(Icons.logout), onPressed: onLogout),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Đã đăng nhập', key: Key('signed-in'), style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            Text('Tài khoản ${_hex(session.accountId).substring(0, 8)}…'),
            Text('Thiết bị ${_hex(session.deviceId).substring(0, 8)}…'),
            Text('KeyPackage trên máy chủ: ${session.remainingKeyPackages}', key: const Key('kp-count')),
          ],
        ),
      ),
    );
  }
}
