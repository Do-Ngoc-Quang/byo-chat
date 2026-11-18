import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

/// Tệp người dùng chọn để gửi. `width`/`height` > 0 chỉ với ảnh đã giải mã được kích thước.
class PickedMedia {
  const PickedMedia({required this.bytes, required this.mime, required this.name, this.width = 0, this.height = 0});
  final Uint8List bytes;
  final String mime, name;
  final int width, height;
}

/// Chọn tệp từ máy. Tách ra để test thay bằng bản giả và để app chọn cài đặt theo nền tảng.
abstract interface class MediaPicker {
  Future<PickedMedia?> pickImage();
  Future<PickedMedia?> pickFile();
}

const _imageTypes = XTypeGroup(label: 'Ảnh', extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'], mimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/webp']);

String mimeOf(String name) {
  final e = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (e) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    _ => 'application/octet-stream',
  };
}

/// Hộp thoại chọn tệp của hệ điều hành (Android, Web, Windows) qua `file_selector`. Chưa kiểm trên máy thật.
class FileSelectorPicker implements MediaPicker {
  const FileSelectorPicker();

  @override
  Future<PickedMedia?> pickImage() => _pick(const [_imageTypes]);

  @override
  Future<PickedMedia?> pickFile() => _pick(const []);

  Future<PickedMedia?> _pick(List<XTypeGroup> groups) async {
    final f = await openFile(acceptedTypeGroups: groups);
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    final mime = mimeOf(f.name);
    final (w, h) = mime.startsWith('image/') ? await imageSize(bytes) : (0, 0);
    return PickedMedia(bytes: bytes, mime: mime, name: f.name, width: w, height: h);
  }
}

/// Kích thước ảnh (0, 0 nếu không giải mã được).
Future<(int, int)> imageSize(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final f = await codec.getNextFrame();
    final r = (f.image.width, f.image.height);
    f.image.dispose();
    codec.dispose();
    return r;
  } on Exception {
    return (0, 0);
  }
}
