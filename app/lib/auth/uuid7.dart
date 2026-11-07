import 'dart:math';
import 'dart:typed_data';

final _rng = Random.secure();

/// UUIDv7 dạng 16 byte (giao-thuc.md mục 2): 48 bit mili giây Unix, version 7, variant 10, phần còn lại ngẫu nhiên.
Uint8List newUuidV7({DateTime? now}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    b[i] = _rng.nextInt(256);
  }
  // 48 bit thời gian big-endian; dùng phép chia để chạy được trên dart2js (không có số 64 bit thật).
  var t = ms;
  for (var i = 5; i >= 0; i--) {
    b[i] = t % 256;
    t ~/= 256;
  }
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  return b;
}
