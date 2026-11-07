# chatcore

Lõi Rust (OpenMLS 0.8, cipher suite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`). Spec: `docs/spec/giao-thuc.md` mục 6-8.

- `crates/chatcore/src/mls.rs`: `Device` (khóa, credential, Commit/Welcome/External Commit, exporter), giới hạn 50/1.000.
- `src/api.rs`: `Core` (một thiết bị + các nhóm, mọi thứ là byte) và `pack`/`unpack`; cầu nối `ffi/` (C ABI) và `wasm/` (`WasmCore`) chỉ bọc `Core::call`. Thêm thao tác mới: sửa `api.rs`, bảng thao tác trong doc của `call`, và `extension ChatCoreMls` bên Dart (`app/lib/core/chatcore_api.dart`). Test: `tests/api.rs`.
- `src/credential.rs`: credential 136 byte (spec 6.1/1.1.1), khóa danh tính tài khoản; `Core::new_device`/`open_device` dựng thiết bị với credential thật, thêm thao tác `credential`, `identity_export`, `key_packages`, `last_resort_key_package`, `verify_key_package`. Vector credential dùng chung với server Go: `tests/credential_vector.txt` (sinh lại: `VECTOR=1 cargo test --release --test credential -- --nocapture vector`, rồi dán vào `server/internal/account/credential_vector_test.go`).
- `src/api/persist.rs`: snapshot/khôi phục đã mã hóa (`Core::snapshot_sealed`, `restore_sealed`, `open_restore`; thao tác `snapshot`), ADR 0008. Test: `tests/persist.rs`.
- `src/sim.rs`: server giả + client mô phỏng, chỉ cho test. `build.rs` sinh Rust từ `proto/` vào `OUT_DIR` (không commit).
- `src/scenarios.rs`: kịch bản dùng chung cho native (`tests/`) và WASM (`wasm/tests/`). `wasm/`: crate `chatcore-wasm` (cầu nối wasm-bindgen, hiện chỉ có khung).
- Test: bất biến 1-5 (`invariants`), recovery/resync/exporter (`recovery`), 1.000 thiết bị so với mốc (`scale`), thuộc tính Protobuf (`proto_props`).
- Lệnh: `cargo test --release`; WASM: `cargo install wasm-bindgen-cli --version 0.2.100 --locked` rồi `CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUNNER=wasm-bindgen-test-runner cargo test --release --target wasm32-unknown-unknown -p chatcore-wasm`; Chrome: thêm `--features browser --test scenarios` (cần chromedriver; cục bộ dùng `NO_HEADLESS=1` rồi mở http://127.0.0.1:8000 bằng trình duyệt); build: `wasm-pack build wasm --target web`.
- Android: `dev/scripts/chatcore-android-test.sh [x86_64|aarch64]` biên dịch test bằng NDK, đẩy vào emulator qua `adb` và chạy (CI job `android`).
- Nguồn gốc: viết theo spec, không nâng từ mã PoC (`poc/` đã xóa); kết quả khớp số đo PoC.
