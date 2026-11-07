// Giao diện lõi `chatcore` cho phần còn lại của app. Cài đặt theo nền tảng (ADR 0006):
// native dùng dart:ffi, Web dùng WASM trong Web Worker.
export 'chatcore_api.dart';
export 'chatcore_stub.dart'
    if (dart.library.ffi) 'chatcore_ffi.dart'
    if (dart.library.js_interop) 'chatcore_web.dart';
