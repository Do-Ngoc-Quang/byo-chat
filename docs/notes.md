# Nhật ký phiên làm việc
Cuối mỗi phiên Claude Code ghi: đã làm gì, quyết định nào, việc dở, câu hỏi cần chốt.

## 06/11/2026
- Thiết kế đóng: chính 1.3.0, spec 1.0.0, màn hình 1.0.0.
- Tên bảng `device_links`, `revocations` đã chốt; cột lấy từ message `DeviceService` trong spec khi viết schema.

## Tổ chức repo
- Chốt quy ước tổ chức: xem `docs/quy-uoc-to-chuc.md` và ADR 0001. Tài liệu chuyển vào `docs/spec/` với tên không số phiên bản.

## Phiên giai đoạn 1 (proto, CI, chatcore)
- Proto: 4 file (thêm `payload.proto`), `CallKind` sang `common.proto`, `reserved` cho số trống; spec 1.0.1, ADR 0002. `buf lint` sạch, `buf` 1.47.2.
- `chatcore` viết lại theo spec vì `poc/` chưa có mã; `poc/` đã xóa theo yêu cầu (ADR 0003). Kết quả khớp PoC: External Commit khóa ký mới giữ leaf cũ (cần Remove), resync cùng khóa tự gỡ; 1.000 thiết bị: 90 KB, tạo 44 ms, nhận 14 ms trên Linux.
- Phát hiện: `max_past_epochs = 0` nên thiết bị phải đọc hết tin của epoch hiện tại trước khi tự dựng Commit (client sẽ cần quy tắc này; test `inv3`). Server phải lưu GroupInfo dạng `MlsMessage` (serialize `MlsMessageOut`), không phải `GroupInfo` thô.
- OpenMLS ghim 0.8.1 (có 0.9.2); API `into_verifiable_group_info` chỉ có ở test-utils, dùng `MlsMessageIn::extract()`.
- Chưa làm/chưa kiểm: crate `wasm/` + `wasm-pack`, test trên Android; kiểm WASM chỉ mới `cargo check`; sinh mã Go/Dart vào `gen/`.
- CI trên PR xanh cả 5 job (buf, test Ubuntu/Windows, wasm check, rfc9420-vectors: 1381 test qua). Windows đã chạy được, gồm test hiệu năng.
- Sinh mã: `proto/buf.gen.yaml` (managed mode, `go_package_prefix` = `github.com/Do-Ngoc-Quang/byo-chat/server/gen`). Tạo `server/go.mod` tối thiểu để `go vet` mã sinh. Dart dùng plugin remote BSR, không truy cập được từ sandbox nên chưa kiểm cục bộ.
- WASM: kịch bản test chuyển vào `chatcore::scenarios` để native và WASM dùng chung; 11 kịch bản (bất biến 1-5, recovery, resync, exporter, giới hạn, 1.000 thiết bị) qua trên Node với wasm-bindgen 0.2.100. Ngưỡng hiệu năng WASM = ngưỡng native x3 (chưa in số đo cụ thể). Chưa kiểm: `wasm-pack build` và chạy trong Chrome (Safari/Android còn nguyên).
- Android: sandbox không có SDK/NDK/KVM nên không chạy được. Viết `dev/scripts/chatcore-android-test.sh` + job CI `android` (reactivecircus/android-emulator-runner, API 34 x86_64, image thường chứ chưa phải 16 KB như PoC). Ngưỡng hiệu năng Android = native x2. `cargo check` cho x86_64 và aarch64 đã qua. Cần xem kết quả CI để sửa script (đường dẫn NDK, lấy exit code qua `adb shell`).
