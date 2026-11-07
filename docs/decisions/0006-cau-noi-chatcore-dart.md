# 0006 — Cầu nối chatcore sang Dart (FFI và WASM)

- **Trạng thái:** Chấp nhận (07/11/2026)
- **Bối cảnh:** App Flutter (Android, Web, sau này desktop) phải gọi lõi Rust `chatcore`. Thiết kế chính chốt FFI cho mobile/desktop và WASM cho Web, nhưng chưa chọn công cụ cầu nối.
- **Quyết định:**
  - Native: crate `chatcore/ffi` (cdylib, C ABI viết tay, không dùng flutter_rust_bridge), Dart nạp bằng `dart:ffi`. Hàm trả chuỗi/byte do Rust cấp phát và có hàm `*_free` đi kèm. Android: `cargo ndk` ghi `libchatcore_ffi.so` vào `app/android/app/src/main/jniLibs/<abi>/` (gitignore).
  - Web: crate `chatcore/wasm` (wasm-bindgen) chạy trong Web Worker `app/web/chatcore_worker.js`; Dart nói chuyện qua `postMessage` bằng `package:web`/`dart:js_interop`. `wasm-pack build wasm --target web --out-dir ../../app/web/pkg` (tự gitignore).
  - Một giao diện Dart `ChatCore` (`app/lib/core/chatcore_api.dart`), toàn bộ hàm `Future` vì Web bất đồng bộ; chọn cài đặt bằng conditional import. Phần còn lại của app chỉ biết `ChatCore`.
  - Logic dùng chung nằm trong crate `chatcore` (ví dụ `chatcore::version()`); `ffi` và `wasm` chỉ là lớp mỏng chuyển đổi kiểu. API trao đổi bằng byte/chuỗi, không lộ kiểu OpenMLS qua ranh giới.
- **Lý do:** bề mặt API nhỏ (vài chục hàm byte vào/byte ra) nên C ABI viết tay rẻ hơn thêm bộ sinh mã; tránh phụ thuộc công cụ sinh mã cho cả hai đích (FFI và WASM) cùng lúc; Worker giữ MLS (CPU nặng, 1.000 thiết bị) ngoài luồng giao diện.
- **Hệ quả:** mỗi hàm mới phải thêm ở ba chỗ (crate lõi, `ffi`, `wasm`) và một chỗ ở mỗi cài đặt Dart; chấp nhận khi API còn nhỏ, xem lại nếu vượt ~50 hàm. Đã kiểm: FFI trên Windows (host) và emulator Android x86_64 (API 37, trang 16 KB); WASM trong Chrome. Chưa kiểm: aarch64, Safari, Windows desktop trong app.
