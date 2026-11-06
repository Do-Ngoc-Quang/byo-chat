# Kế hoạch và tiến độ

Nơi DUY NHẤT theo dõi tiến độ. Cuối mỗi phiên tick checklist; `notes.md` chỉ ghi quyết định và vấn đề phát sinh.
Chỉ ghi thứ tự và cổng nghiệm thu, không ghi mốc thời gian. Chưa đạt cổng thì chưa sang giai đoạn sau.

> Nguồn: thứ tự làm trong `CLAUDE.md` (theo mục 16 tài liệu chính) và tiêu chí PoC/kiểm thử trong `docs/spec/giao-thuc.md` mục 8. Sơ đồ lộ trình gốc không xuất được sang markdown nên cổng nghiệm thu dưới đây là **đề xuất rút ra từ spec, cần xác nhận** khi vào từng giai đoạn.

## Tổng quan
| # | Giai đoạn | Cổng nghiệm thu (đề xuất) | Trạng thái |
|---|---|---|---|
| 0 | PoC | Bốn PoC đạt tiêu chí (trừ mục chưa kiểm) | Xong; 3 mục còn lại tạm hoãn (pending) |
| 1 | Proto, CI, `chatcore` | 5 bất biến đúng trên Windows, WASM, Android; `buf breaking` chạy trong CI; test hiệu năng không tệ hơn mốc | Đang làm |
| 2 | Server tối thiểu | Gateway và Message Service chạy cục bộ; `SendMessage` từ chối `EPOCH_MISMATCH`; con trỏ hộp thư idempotent; qua kiểm thử chèn lỗi | Chưa bắt đầu |
| 3 | Lát cắt dọc | Đăng nhập và chat 1-1 E2EE giữa Android và Web, đầu cuối | Chưa bắt đầu |
| 4 | Nhóm, đa thiết bị, backup | Nhóm, thêm thiết bị bằng External Commit, khôi phục có và không có backup; 5 bất biến đúng | Chưa bắt đầu |
| 5 | Media | Gửi nhận ảnh/tệp mã hóa qua R2 | Chưa bắt đầu |
| 6 | Gọi video | Cuộc gọi 4 người có E2EE trên mọi nền tảng, đổi khóa SFrame đúng quy tắc | Chưa bắt đầu |

## Giai đoạn 0 — PoC
- [x] MLS đa nền tảng: Windows, WASM trên Chrome, Android emulator
- [x] Nhóm 1.000 thiết bị, Commit cuối 92 KB, tạo 33 ms, nhận 11 ms
- [x] Ca khôi phục không backup (External Commit, Remove leaf cũ)
- [x] Gọi video E2EE trên Chrome với xoay khóa
- [x] Tải gateway: 10.000 kết nối, p95 0,33 ms, 67 MB
- [x] SQLite trên OPFS và cầu nối Dart-JavaScript trong Flutter Web
- [ ] (hoãn) MLS trên máy ARM thật
- [ ] (hoãn) Video trên Flutter Android và Safari
- [x] `poc/` đã xóa (ADR 0003); không chép mã PoC

## Giai đoạn 1 — Proto, CI, `chatcore`
- [x] `proto/chat/v1/`: `common.proto`, `ws.proto`, `services.proto`, `payload.proto` từ spec; `buf lint` sạch (ADR 0002)
- [x] CI `proto.yml`: `buf lint` và `buf breaking` (đã xanh trên GitHub; `breaking` bỏ qua tới khi `main` có proto)
- [ ] Sinh mã Go, Rust, Dart vào `gen/` (không commit)
- [x] `chatcore/`: Rust workspace (viết lại theo spec vì `poc/` chưa có mã; xem notes)
- [x] Test: bất biến 1-5 (spec mục 8), mô phỏng nhiều thiết bị với server giả
- [x] Test: ca recovery, resync, scale 1.000 thiết bị, exporter
- [x] Test vector RFC 9420 cho OpenMLS (job CI `rfc9420-vectors`, 1381 test qua)
- [x] Kiểm thử thuộc tính cho mã hóa/giải mã Protobuf
- [ ] CI `chatcore.yml`: có `cargo test --release` (Linux, Windows, đã xanh) và `cargo check` WASM; còn thiếu crate `wasm/` + `wasm-pack`
- [x] Mốc hiệu năng: kiểm không tệ hơn số đo mốc (`tests/scale.rs`, Linux: 90 KB, tạo 44 ms, nhận 14 ms)
- [x] Xóa `poc/` (ADR 0003)

## Giai đoạn 2 — Server tối thiểu
- [ ] `dev/docker-compose.yml`: Postgres, DynamoDB local, NATS JetStream, Valkey
- [ ] Gateway: WebSocket, `Hello`, `proto_version`
- [ ] Message Service: `SendMessage`, kiểm tra epoch, `SubmitCommit`
- [ ] Hộp thư: con trỏ ghi qua hàng đợi bền, idempotent theo `(conv_id, seq)`
- [ ] Schema Postgres/DynamoDB (gồm `device_links`, `revocations`)
- [ ] Kiểm thử chèn lỗi: mất kết nối khi `SubmitCommit`; sập giữa ghi Commit và con trỏ
- [ ] CI `server.yml`: `go vet`, `go test`

## Giai đoạn 3 — Lát cắt dọc
- [ ] `app/`: khung Flutter, tích hợp `chatcore` (FFI Android, WASM Web)
- [ ] Đăng nhập: OTP, passkey
- [ ] Chat 1-1 E2EE Android và Web
- [ ] Đo ngưỡng payload push FCM
- [ ] CI `app.yml`: `flutter analyze`, `flutter test`

## Giai đoạn 4 — Nhóm, đa thiết bị, backup
- [ ] Nhóm, thêm/gỡ thành viên
- [ ] Thiết bị mới vào nhóm bằng External Commit; liên kết thiết bị
- [ ] Backup và khôi phục tài khoản
- [ ] Giới hạn 50 thiết bị mỗi Commit, 1.000 mỗi nhóm
- [ ] Đo kích thước Welcome, Commit thêm 1 thiết bị
- [ ] Desktop

## Giai đoạn 5 — Media
- [ ] Media mã hóa lên Cloudflare R2 (spec mục 11 tài liệu chính)

## Giai đoạn 6 — Gọi video
- [ ] LiveKit, khóa SFrame = `Exporter("call", call_id, 32)`
- [ ] Đổi khóa khi có người vào/ra; giữ khóa cũ và mới theo chỉ số khóa
- [ ] Kiểm Flutter Android và Safari

## Điểm mở từ spec (làm ở giai đoạn tương ứng)
- [ ] Chuyển lịch sử giữa thiết bị chưa đặc tả (giai đoạn 4)
- [ ] Tin tự hủy: hành vi khi đổi `chat_policy` (giai đoạn 4)
- [ ] Ảnh nhóm trong group context extension (giai đoạn 4-5)
- [ ] Khóa danh tính tài khoản đổi, Key Transparency (sau giai đoạn 4)

## Rủi ro cần theo dõi
Xem tài liệu chính mục 16: một người là điểm lỗi duy nhất; lỗi mật mã (audit độc lập); chi phí video; spam; pháp lý mật mã và dữ liệu (tư vấn trước beta mở); phạm vi phình ra.
