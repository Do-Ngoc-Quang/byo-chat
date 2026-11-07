import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'blob_store.dart';

/// Kho blob bằng tệp trong thư mục dữ liệu riêng của app. `dir` ghi đè để test.
Future<BlobStore> openBlobStore({Directory? dir}) async =>
    FileBlobStore(dir ?? Directory('${(await getApplicationSupportDirectory()).path}/byo-chat'));

class FileBlobStore implements BlobStore {
  FileBlobStore(this.dir);

  final Directory dir;

  File _f(String name) => File('${dir.path}/$name');

  @override
  Future<Uint8List?> read(String name) async {
    final f = _f(name);
    return await f.exists() ? await f.readAsBytes() : null;
  }

  @override
  Future<void> write(String name, Uint8List data) async {
    await dir.create(recursive: true);
    // Ghi ra tệp tạm rồi đổi tên: mất điện giữa chừng chỉ để lại tệp tạm, bản cũ còn nguyên.
    final tmp = _f('$name.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(_f(name).path);
  }

  @override
  Future<void> delete(String name) async {
    final f = _f(name);
    if (await f.exists()) await f.delete();
  }
}
