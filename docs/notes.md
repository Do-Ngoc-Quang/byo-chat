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
- Chưa làm/chưa kiểm: chạy KAT RFC 9420 (lệnh chạy mã clone từ OpenMLS bị chặn trong phiên, job CI chỉ viết); CI chưa chạy trên GitHub; crate `wasm/` + `wasm-pack`, test trên Android; kiểm WASM chỉ mới `cargo check`; Windows chưa chạy; sinh mã Go/Dart vào `gen/`.
