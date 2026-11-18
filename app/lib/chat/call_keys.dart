import 'dart:typed_data';

/// Vòng khóa SFrame của một cuộc gọi, khớp `chatcore::sframe::KeyRing` (giao-thuc.md 6.9):
/// chỉ số khóa = epoch (u32); khóa mới nhận được ngay; khóa gửi chuyển sau 1 giây; khóa cũ giữ 10 giây.
/// Thời gian do bên gọi truyền vào (ms, đơn điệu) nên test không cần ngủ.
class SframeKeyRing {
  SframeKeyRing(int epoch, Uint8List key) : _sending = keyId(epoch) {
    _keys[_sending] = _Entry(key, null);
  }

  static const switchDelayMs = 1000;
  static const keepOldMs = 10000;

  static int keyId(int epoch) => epoch & 0xffffffff;

  final _keys = <int, _Entry>{};
  int? _pendingId;
  int _pendingAt = 0;
  int _sending;

  /// Đã áp dụng Commit sang `epoch` mới với khóa `key`. false nếu epoch không mới hơn khóa mới nhất (bỏ qua).
  bool onEpoch(int epoch, Uint8List key, int nowMs) {
    final id = keyId(epoch);
    if (_keys.isNotEmpty && id <= _newest) return false;
    for (final e in _keys.values) {
      e.retireAt ??= nowMs + keepOldMs;
    }
    _keys[id] = _Entry(key, null);
    _pendingId = id;
    _pendingAt = nowMs + switchDelayMs;
    return true;
  }

  int get _newest => _keys.keys.reduce((a, b) => a > b ? a : b);

  /// Khóa mã hóa khung gửi đi lúc `nowMs` (chuyển sang khóa mới nếu đã đến hạn).
  (int id, Uint8List key) sendKey(int nowMs) {
    if (_pendingId != null && nowMs >= _pendingAt) {
      _sending = _pendingId!;
      _pendingId = null;
    }
    _expire(nowMs);
    return (_sending, _keys[_sending]!.key);
  }

  /// Khóa giải mã khung mang chỉ số `id`; null nếu chưa từng có hoặc đã hết hạn.
  Uint8List? recvKey(int id, int nowMs) {
    _expire(nowMs);
    return _keys[id]?.key;
  }

  void _expire(int nowMs) {
    _keys.removeWhere((id, e) => id != _sending && e.retireAt != null && nowMs >= e.retireAt!);
  }

  int get length => _keys.length;
}

class _Entry {
  _Entry(this.key, this.retireAt);
  final Uint8List key;
  int? retireAt;
}
