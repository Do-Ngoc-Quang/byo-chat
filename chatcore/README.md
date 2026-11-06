# chatcore

Lõi Rust (OpenMLS 0.8, cipher suite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`). Spec: `docs/spec/giao-thuc.md` mục 6-8.

- `crates/chatcore/src/mls.rs`: `Device` (khóa, credential, Commit/Welcome/External Commit, exporter), giới hạn 50/1.000.
- `src/sim.rs`: server giả + client mô phỏng, chỉ cho test. `build.rs` sinh Rust từ `proto/` vào `OUT_DIR` (không commit).
- `src/scenarios.rs`: kịch bản dùng chung cho native (`tests/`) và WASM (`wasm/tests/`). `wasm/`: crate `chatcore-wasm` (cầu nối wasm-bindgen, hiện chỉ có khung).
- Test: bất biến 1-5 (`invariants`), recovery/resync/exporter (`recovery`), 1.000 thiết bị so với mốc (`scale`), thuộc tính Protobuf (`proto_props`).
- Lệnh: `cargo test --release`; WASM: `cargo install wasm-bindgen-cli --version 0.2.100 --locked` rồi `CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUNNER=wasm-bindgen-test-runner cargo test --release --target wasm32-unknown-unknown -p chatcore-wasm`; Chrome: thêm `--features browser --test scenarios` (cần chromedriver; cục bộ dùng `NO_HEADLESS=1` rồi mở http://127.0.0.1:8000 bằng trình duyệt); build: `wasm-pack build wasm --target web`.
- Android: `dev/scripts/chatcore-android-test.sh [x86_64|aarch64]` biên dịch test bằng NDK, đẩy vào emulator qua `adb` và chạy (CI job `android`).
- Nguồn gốc: viết theo spec, không nâng từ mã PoC (`poc/` đã xóa); kết quả khớp số đo PoC.
