# Kế hoạch và tiến độ

Nơi DUY NHẤT theo dõi tiến độ. Cuối mỗi phiên tick checklist; `notes.md` chỉ ghi quyết định và vấn đề phát sinh.
Chỉ ghi thứ tự và cổng nghiệm thu, không ghi mốc thời gian. Chưa đạt cổng thì chưa sang giai đoạn sau.

> **Bối cảnh môi trường:** không dùng máy thật; mọi kiểm thử chạy trên mô phỏng (emulator Android x86_64, Chrome/Node headless, runner CI). Mục cần thiết bị thật (ARM, Safari, trang 16 KB, FCM thật, Flutter trên thiết bị...) ghi là **"hoãn, cần thiết bị thật"**, KHÔNG chặn "xong" của giai đoạn. Khi có thiết bị thật thì kiểm lại và tick riêng. Xem `docs/notes.md`.

> Nguồn: thứ tự làm trong `CLAUDE.md` (theo mục 16 tài liệu chính) và tiêu chí PoC/kiểm thử trong `docs/spec/giao-thuc.md` mục 8. Sơ đồ lộ trình gốc không xuất được sang markdown nên cổng nghiệm thu dưới đây là **đề xuất rút ra từ spec, cần xác nhận** khi vào từng giai đoạn.

## Tổng quan
| # | Giai đoạn | Cổng nghiệm thu (đề xuất) | Trạng thái |
|---|---|---|---|
| 0 | PoC | Bốn PoC đạt tiêu chí (trừ mục chưa kiểm) | Xong; 3 mục còn lại tạm hoãn (pending) |
| 1 | Proto, CI, `chatcore` | 5 bất biến đúng trên Windows, WASM, Android (emulator là đủ); `buf breaking` chạy trong CI; test hiệu năng không tệ hơn mốc | Xong (PR #3 đã merge; mục cần thiết bị thật hoãn, xem bên dưới) |
| 2 | Server tối thiểu | Gateway và Message Service chạy cục bộ; `SendMessage` từ chối `EPOCH_MISMATCH`; con trỏ hộp thư idempotent; qua kiểm thử chèn lỗi | Xong (PR #5; CI `server.yml` xanh; còn chờ merge) |
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
- [ ] (hoãn, cần thiết bị thật) MLS trên máy ARM thật
- [ ] (hoãn, cần thiết bị thật) Video trên Flutter Android và Safari
- [x] `poc/` đã xóa (ADR 0003); không chép mã PoC

## Giai đoạn 1 — Proto, CI, `chatcore`
- [x] `proto/chat/v1/`: `common.proto`, `ws.proto`, `services.proto`, `payload.proto` từ spec; `buf lint` sạch (ADR 0002)
- [x] CI `proto.yml`: `buf lint` và `buf breaking` (đã xanh trên GitHub; `breaking` bỏ qua tới khi `main` có proto)
- [x] Sinh mã Go, Rust, Dart vào `gen/` (không commit): Rust qua `build.rs`; Go+Connect qua `buf generate` (đã `go vet` cục bộ); Dart qua plugin remote của BSR, chỉ kiểm được trên CI (job `generate`)
- [x] `chatcore/`: Rust workspace (viết lại theo spec vì `poc/` chưa có mã; xem notes)
- [x] Test: bất biến 1-5 (spec mục 8), mô phỏng nhiều thiết bị với server giả
- [x] Test: ca recovery, resync, scale 1.000 thiết bị, exporter
- [x] Test vector RFC 9420 cho OpenMLS (job CI `rfc9420-vectors`, 1381 test qua)
- [x] Kiểm thử thuộc tính cho mã hóa/giải mã Protobuf
- [x] CI `chatcore.yml` xanh: `cargo test --release` (Linux, Windows), test WASM trên Node và Chrome headless, `wasm-pack build --target web`, Android emulator, vector RFC 9420 (job `rfc9420-vectors` còn đang chạy ở lần chạy gần nhất)
- [x] Android: job CI `android` (emulator x86_64 API 34, trang 4 KB, `dev/scripts/chatcore-android-test.sh`) xanh, 17 test qua gồm 1.000 thiết bị. Hoãn, cần thiết bị thật (không chặn): trang 16 KB, aarch64, máy ARM thật
- [x] Mốc hiệu năng: kiểm không tệ hơn số đo mốc (`tests/scale.rs`, Linux: 90 KB, tạo 44 ms, nhận 14 ms)
- [x] Xóa `poc/` (ADR 0003)

## Giai đoạn 2 — Server tối thiểu
- [x] `dev/docker-compose.yml`: Postgres, DynamoDB local, NATS JetStream, Valkey. Sandbox không có Docker daemon nên file compose chưa chạy; đã chạy cùng thành phần theo cách khác (Postgres 16 cài sẵn, DynamoDB Local 2.5.2 qua Maven, NATS nhúng/`nats-server`). Valkey chưa dùng (chưa có presence/rate limit phân tán)
- [x] Gateway: WebSocket, `Hello`, `proto_version`, `Welcome`, tồn đọng, `SyncDone`, `Ack` + cửa sổ, heartbeat, mã đóng 4001/4002/4003/4004/4009/4010, giới hạn tốc độ
- [x] Message Service: `SendMessage` (EPOCH_MISMATCH, khử trùng), `SubmitCommit` (điều kiện epoch, Idempotency-Key, phân quyền, External Commit), `CreateConversation`, `SubmitProposal`, `FetchLog`, `GetGroupInfo`, `ListConversations`; Connect RPC
- [x] Hộp thư: con trỏ ghi qua JetStream, idempotent theo `(conv_id, seq)`, kèm `Repair` quét việc dở (ADR 0004)
- [x] Schema Postgres (`internal/store/postgres/migrations/0001_init.sql`, gồm `device_links`, `revocations`) và bảng DynamoDB (`EnsureTables`)
- [x] Kiểm thử chèn lỗi: gửi lại `SubmitCommit` sau khi mất phản hồi; sập giữa ghi Commit và con trỏ (mất job, khởi động lại tiến trình, `Repair` hoàn tất). Giới hạn: mô phỏng ở tầng dịch vụ/hàng đợi, chưa kill tiến trình thật hay cắt TCP giữa chừng
- [x] CI `server.yml` xanh trên GitHub (PR #5, commit fde164c): `go vet`, `gofmt`, `go test -race` ở chế độ bộ nhớ, rồi trên Postgres + DynamoDB Local + NATS JetStream nhúng
- [ ] (hoãn sang giai đoạn sau, không chặn cổng) Server kiểm tra credential của External Commit (cần phân tích `PublicMessage` MLS ở Go); `KeyService`/`DeviceService`/`AuthService`; presence, `DeliveredReceipt`, HTTP streaming `/v1/stream`, rời nhóm (`leaving`), cache Valkey cho thành viên; GSI thưa thay Scan cho `PendingFanouts`; nhiều node gateway (đóng kết nối cũ ở node khác bằng 4010)

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
- [ ] Kiểm Flutter Android và Safari (cần thiết bị thật; làm mô phỏng được đến đâu thì ghi rõ giới hạn)

## Điểm mở từ spec (làm ở giai đoạn tương ứng)
- [ ] Chuyển lịch sử giữa thiết bị chưa đặc tả (giai đoạn 4)
- [ ] Tin tự hủy: hành vi khi đổi `chat_policy` (giai đoạn 4)
- [ ] Ảnh nhóm trong group context extension (giai đoạn 4-5)
- [ ] Khóa danh tính tài khoản đổi, Key Transparency (sau giai đoạn 4)

## Rủi ro cần theo dõi
Xem tài liệu chính mục 16: một người là điểm lỗi duy nhất; lỗi mật mã (audit độc lập); chi phí video; spam; pháp lý mật mã và dữ liệu (tư vấn trước beta mở); phạm vi phình ra.
