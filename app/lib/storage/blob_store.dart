import 'dart:typed_data';

export 'blob_store_stub.dart'
    if (dart.library.io) 'blob_store_io.dart'
    if (dart.library.js_interop) 'blob_store_web.dart';

/// Kho blob lớn (snapshot đã mã hóa). Nội dung đã được mã hóa bởi chatcore, nên kho không cần bí mật.
/// Native: tệp trong thư mục dữ liệu app; Web: localStorage (đủ cho giai đoạn này, OPFS/IndexedDB sau).
abstract interface class BlobStore {
  Future<Uint8List?> read(String name);

  /// Ghi nguyên tử: đọc lại không bao giờ thấy nửa bản cũ nửa bản mới.
  Future<void> write(String name, Uint8List data);
  Future<void> delete(String name);
}

class MemoryBlobStore implements BlobStore {
  final map = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String name) async => map[name];

  @override
  Future<void> write(String name, Uint8List data) async => map[name] = Uint8List.fromList(data);

  @override
  Future<void> delete(String name) async => map.remove(name);
}
