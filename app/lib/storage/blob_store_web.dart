import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'blob_store.dart';

/// Kho blob trên Web bằng localStorage (base64). Giới hạn ~5 MB mỗi origin: đủ cho snapshot của vài
/// trăm nhóm nhỏ; nhóm lớn (hàng trăm thiết bị) cần chuyển sang OPFS/IndexedDB (ghi trong ADR 0008).
Future<BlobStore> openBlobStore() async => LocalStorageBlobStore();

class LocalStorageBlobStore implements BlobStore {
  static const _prefix = 'byo-chat/blob/';

  @override
  Future<Uint8List?> read(String name) async {
    final v = web.window.localStorage.getItem('$_prefix$name');
    return v == null ? null : base64.decode(v);
  }

  @override
  Future<void> write(String name, Uint8List data) async {
    // setItem là nguyên tử với từng khóa; quá hạn mức thì ném QuotaExceededError (để lỗi nổi lên).
    web.window.localStorage.setItem('$_prefix$name', base64.encode(data));
  }

  @override
  Future<void> delete(String name) async => web.window.localStorage.removeItem('$_prefix$name');
}
