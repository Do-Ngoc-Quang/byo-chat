import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'chatcore_api.dart';

typedef _VersionC = Pointer<Utf8> Function();
typedef _StrFreeC = Void Function(Pointer<Utf8>);
typedef _StrFree = void Function(Pointer<Utf8>);
typedef _OpenC = Pointer<Void> Function(Pointer<Uint8>, UintPtr, Pointer<Pointer<Utf8>>);
typedef _Open = Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
typedef _OpenDeviceC = Pointer<Void> Function(Pointer<Uint8>, UintPtr, Pointer<Pointer<Utf8>>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _Close = void Function(Pointer<Void>);
typedef _CallC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, UintPtr, Pointer<Pointer<Uint8>>, Pointer<UintPtr>);
typedef _Call = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<UintPtr>);
typedef _BufFreeC = Void Function(Pointer<Uint8>, UintPtr);
typedef _BufFree = void Function(Pointer<Uint8>, int);

/// Mở lõi qua FFI. `path` ghi đè đường dẫn thư viện (dùng khi test trên máy dev);
/// nếu bỏ trống thì lấy biến môi trường `CHATCORE_LIB`, rồi tên mặc định theo nền tảng.
Future<ChatCore> openChatCore({String? path}) async {
  final lib = DynamicLibrary.open(
    path ?? Platform.environment['CHATCORE_LIB'] ?? _defaultName(),
  );
  return _FfiChatCore(lib);
}

String _defaultName() {
  if (Platform.isWindows) return 'chatcore_ffi.dll';
  if (Platform.isMacOS || Platform.isIOS) return 'libchatcore_ffi.dylib';
  return 'libchatcore_ffi.so'; // Android, Linux
}

class _FfiChatCore implements ChatCore {
  _FfiChatCore(DynamicLibrary lib)
      : _version = lib.lookupFunction<_VersionC, _VersionC>('chatcore_version'),
        _strFree = lib.lookupFunction<_StrFreeC, _StrFree>('chatcore_string_free'),
        _open = lib.lookupFunction<_OpenC, _Open>('chatcore_open'),
        _openDevice = lib.lookupFunction<_OpenDeviceC, _Open>('chatcore_open_device'),
        _openRestore = lib.lookupFunction<_OpenDeviceC, _Open>('chatcore_open_restore'),
        _close = lib.lookupFunction<_CloseC, _Close>('chatcore_close'),
        _call = lib.lookupFunction<_CallC, _Call>('chatcore_call'),
        _bufFree = lib.lookupFunction<_BufFreeC, _BufFree>('chatcore_buf_free');

  final _VersionC _version;
  final _StrFree _strFree;
  final _Open _open;
  final _Open _openDevice;
  final _Open _openRestore;
  final _Close _close;
  final _Call _call;
  final _BufFree _bufFree;
  Pointer<Void>? _handle;

  /// Đọc rồi giải phóng chuỗi lỗi của Rust; null nếu không có lỗi.
  String? _takeError(Pointer<Utf8> p) {
    if (p == nullptr) return null;
    try {
      return p.toDartString();
    } finally {
      _strFree(p);
    }
  }

  @override
  Future<String> version() async {
    final p = _version();
    try {
      return p.toDartString();
    } finally {
      _strFree(p);
    }
  }

  @override
  Future<void> open(Uint8List identity) => _openWith(_open, identity);

  @override
  Future<void> openDeviceRaw(Uint8List packedArgs) => _openWith(_openDevice, packedArgs);

  @override
  Future<void> openRestoreRaw(Uint8List packedArgs) => _openWith(_openRestore, packedArgs);

  Future<void> _openWith(_Open fn, Uint8List data) async {
    if (_handle != null) throw StateError('đã open');
    final buf = malloc<Uint8>(data.length);
    final err = malloc<Pointer<Utf8>>();
    try {
      buf.asTypedList(data.length).setAll(0, data);
      final h = fn(buf, data.length, err);
      final msg = _takeError(err.value);
      if (msg != null) throw ChatCoreException(msg);
      _handle = h;
    } finally {
      malloc.free(buf);
      malloc.free(err);
    }
  }

  @override
  Future<Uint8List> callRaw(String op, Uint8List packedArgs) async {
    final h = _handle ?? (throw StateError('chưa open'));
    final opP = op.toNativeUtf8();
    final buf = malloc<Uint8>(packedArgs.length);
    final out = malloc<Pointer<Uint8>>();
    final outLen = malloc<UintPtr>();
    try {
      buf.asTypedList(packedArgs.length).setAll(0, packedArgs);
      final msg = _takeError(_call(h, opP, buf, packedArgs.length, out, outLen));
      if (msg != null) throw ChatCoreException(msg);
      final n = outLen.value;
      final result = Uint8List.fromList(out.value.asTypedList(n)); // sao chép trước khi giải phóng
      _bufFree(out.value, n);
      return result;
    } finally {
      malloc.free(opP);
      malloc.free(buf);
      malloc.free(out);
      malloc.free(outLen);
    }
  }

  @override
  Future<void> dispose() async {
    final h = _handle;
    if (h != null) _close(h);
    _handle = null;
  }
}
