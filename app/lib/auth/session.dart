import 'dart:typed_data';

import '../core/chatcore.dart';
import '../gen/chat/v1/services.pb.dart';

/// Thiết bị đã đăng nhập: lõi MLS đang mở, token, và số liệu hiển thị.
/// Mọi thay đổi trạng thái MLS phải kết thúc bằng `SessionStore.save` (ADR 0008).
class Session {
  Session(this.accountId, this.deviceId, this.core, this.tokens, this.remainingKeyPackages);

  final Uint8List accountId, deviceId;
  final ChatCore core;
  TokenPair tokens;
  int remainingKeyPackages;
}
