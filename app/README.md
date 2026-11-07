# app

Ứng dụng Flutter (Android, Web; desktop ở giai đoạn 4). Gọi lõi `chatcore` qua cầu nối ở ADR 0006 (`docs/decisions/0006-cau-noi-chatcore-dart.md`). Spec màn hình: `docs/spec/man-hinh.md`.

- `lib/core/`: giao diện `ChatCore` và cài đặt theo nền tảng (`chatcore_ffi.dart`, `chatcore_web.dart`).
- `web/chatcore_worker.js`: Web Worker nạp WASM từ `web/pkg/` (sinh ra, không commit).
- Kiểm tra: `flutter analyze && flutter test`. Test FFI cần thư viện: `cargo build --release -p chatcore-ffi` (trong `chatcore/`) rồi đặt `CHATCORE_LIB` trỏ tới `chatcore_ffi.dll`/`libchatcore_ffi.so`; thiếu biến thì test đó bị bỏ qua.
- Web: `wasm-pack build wasm --target web --out-dir ../../app/web/pkg` (trong `chatcore/`) rồi `flutter run -d chrome`.
- Android: `cargo ndk -t x86_64 -o ../app/android/app/src/main/jniLibs build --release -p chatcore-ffi` (trong `chatcore/`, cần `ANDROID_NDK_HOME`), rồi `flutter test integration_test -d <emulator>`.
- Web (kiểm MLS trong trình duyệt): `flutter build web --target integration_test/web_smoke.dart`, phục vụ `build/web` bằng HTTP tĩnh rồi mở trang, thấy `MLS OK`. Flutter chưa chạy `integration_test` trên Web nếu thiếu chromedriver.
- Kịch bản MLS dùng chung: `integration_test/mls_scenario.dart` (VM/FFI, Android, Web).
- Mã Dart từ proto: `cd proto && buf generate --template buf.gen.app.yaml` (vào `app/lib/gen/`, không commit; cần chạy trước `flutter analyze/test`).
- Địa chỉ server: `--dart-define=CHAT_API=http://host:8080` (mặc định Web `localhost:8080`, Android emulator `10.0.2.2:8080`). Bản debug Android cho phép HTTP (`src/debug/AndroidManifest.xml`); release thì không.
- E2E với server thật: chạy server với `CHAT_DEV_OTP=1 CHAT_DEV_OTP_CODE=123456` (và `CHAT_CORS_ORIGINS=<origin Web>` khi chạy trên Web), rồi: VM `CHAT_API=http://localhost:8080 CHATCORE_LIB=... flutter test`; Android `flutter test integration_test/core_bridge_test.dart -d <emulator> --dart-define=CHAT_API=http://10.0.2.2:8080`; Web build `web_smoke.dart` với `--dart-define=CHAT_API=...`.
- Lưu bền: `lib/storage/` (`SecretStore`, `BlobStore`, `SessionStore`), ADR 0008. Mọi thay đổi trạng thái MLS phải kết thúc bằng `SessionStore.save(session)`. Kịch bản thật: `integration_test/persist_e2e.dart` (VM dùng kho tệp + bí mật trong bộ nhớ vì plugin không chạy trong `flutter test`; Android/Web dùng kho thật).
- Chat: `lib/net/gateway_client.dart` (WebSocket), `lib/chat/` (`ChatEngine`, `LocalDoc`), `lib/ui/conversations_page.dart`, `chat_page.dart`; ADR 0009. E2E hai thiết bị: `integration_test/chat_e2e.dart` (cần server dev, xem trên). Server dev cho Web cần `CHAT_CORS_ORIGINS` chứa origin của app (cả CORS lẫn WebSocket).
