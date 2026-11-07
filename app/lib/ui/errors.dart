import 'package:flutter/material.dart';

import '../auth/login_controller.dart' show describeError;
import '../chat/backup.dart' show BackupException;
import '../chat/chat_engine.dart';
import '../core/chatcore.dart';
import '../gen/chat/v1/common.pbenum.dart';
import '../net/connect_client.dart';

/// Chạy một thao tác và báo lỗi bằng snackbar tiếng Việt. Trả true nếu thành công.
Future<bool> guarded(BuildContext context, Future<void> Function() body) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String m) => messenger.showSnackBar(SnackBar(content: Text(m)));
  try {
    await body();
    return true;
  } on ConnectException catch (e) {
    say(e.errorCode == ErrorCode.ERROR_CODE_NOT_FOUND ? 'Không tìm thấy.' : describeError(e));
  } on IdentityChangedException {
    say('Khóa bảo mật của người này đã thay đổi. Hãy xác minh lại trước khi tiếp tục.');
  } on ChatException catch (e) {
    say(e.message);
  } on BackupException catch (e) {
    say(e.message);
  } on ChatCoreException catch (e) {
    say('Lỗi lõi mã hóa: ${e.message}');
  } on FormatException catch (e) {
    say(e.message);
  }
  return false;
}
