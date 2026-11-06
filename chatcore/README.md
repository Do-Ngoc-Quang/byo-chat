# chatcore

Lõi Rust (OpenMLS 0.8, cipher suite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`). Spec: `docs/spec/giao-thuc.md` mục 6-8.

- `crates/chatcore/src/mls.rs`: `Device` (khóa, credential, Commit/Welcome/External Commit, exporter), giới hạn 50/1.000.
- `src/sim.rs`: server giả + client mô phỏng, chỉ cho test. `build.rs` sinh Rust từ `proto/` vào `OUT_DIR` (không commit).
- Test: bất biến 1-5 (`invariants`), recovery/resync/exporter (`recovery`), 1.000 thiết bị so với mốc (`scale`), thuộc tính Protobuf (`proto_props`).
- Lệnh: `cargo test --release`; WASM: `cargo check --release --target wasm32-unknown-unknown -p chatcore` (crate `wasm/` và `wasm-pack` chưa có).
- Nguồn gốc: viết theo spec, không nâng từ mã PoC (`poc/` đã xóa); kết quả khớp số đo PoC.
