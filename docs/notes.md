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
- WASM trong Chrome: 11/11 qua trên HeadlessChrome 153 (cục bộ, runner `NO_HEADLESS=1` + Playwright vì sandbox không có chromedriver). Feature `browser` của `chatcore-wasm` bật `run_in_browser`. Bước CI Chrome dùng `CHROMEWEBDRIVER` của runner, chưa chạy.
- CI (commit 123f846): wasm (Node, Chrome, wasm-pack build) và android xanh. Android x86_64 API 34: 17 test qua, trang bộ nhớ 4096 B (chưa phải 16 KB). Chưa in số đo thực Commit trên WASM/Android. Còn: trang 16 KB, aarch64, ARM thật.

## Bối cảnh môi trường (06/11/2026)
- Không dùng máy thật; mọi thứ chạy mô phỏng: emulator Android x86_64 (trang 4 KB), Chrome/Node headless, runner GitHub Actions. Số đo hiệu năng từ môi trường này không so trực tiếp với mốc Windows native, chỉ dùng để bắt suy giảm lớn.
- Quy tắc: mục cần thiết bị thật (MLS trên ARM thật, Flutter trên Android/Safari thật, trang 16 KB, ngưỡng payload FCM thật, đo pin/mạng) ghi "hoãn, cần thiết bị thật" trong `ke-hoach.md`, nêu rõ giới hạn của kiểm thử mô phỏng, và không chặn "xong" của giai đoạn. Mô phỏng được thì làm (ví dụ aarch64 qua emulator ARM nếu CI có).
- Áp dụng ngay: cổng giai đoạn 1 chỉ cần emulator; điểm hở còn lại là `buf breaking` chưa chạy thật (không liên quan thiết bị) và merge PR #3.

## Kết thúc giai đoạn 1 (06/11/2026)
- PR #3 đã merge vào `main`; CI xanh đủ 7 job. `buf breaking --against origin/main` chạy thật cục bộ sau merge: qua.
- Việc hoãn, cần thiết bị thật (không chặn): MLS trên ARM thật, trang 16 KB, aarch64, video Flutter Android/Safari. Chưa in số đo hiệu năng WASM/Android (chỉ kiểm ngưỡng).
- Giai đoạn kế: 2 (server tối thiểu). Nhánh mới tách từ `main` mới nhất.

## Phiên giai đoạn 2 (server tối thiểu, 06/11/2026)
- Nhánh `feat/server-phase2`. Chưa commit/push (chờ lệnh). Thiết kế ở ADR 0004.
- Đã chạy thật trên Postgres 16, DynamoDB Local 2.5.2, NATS JetStream; `go test -race ./...` qua cả ở chế độ bộ nhớ lẫn hạ tầng thật; binary `cmd/gateway` khởi động, migration tạo 14 bảng, `/healthz` 200. Sandbox không có Docker nên `docker-compose.yml` chưa chạy.
- Kiểm chứng bằng hợp đồng chung `storetest` cho cả bộ nhớ lẫn DynamoDB/Postgres thật (cấp `seq` liền mạch khi tranh chấp, đúng một Commit thắng mỗi epoch, dedup, con trỏ idempotent, GetLog qua nhiều bucket). Phát hiện khi test: cấp `seq` lạc quan cần backoff có jitter (16 lần thử không đủ cho 40 gửi đồng thời).
- Phát hiện: `coder/websocket` đóng cứng kết nối khi context của `Read` hết hạn, không gửi được mã 4001; dùng timer đóng từ ngoài. `Close` chờ bắt tay đóng tới 5 giây nên đóng kết nối cũ/drain phải chạy bất đồng bộ.
- Đã sửa spec giao-thuc.md lên 1.1.0: làm rõ phân quyền `SubmitCommit` (path update và gỡ thiết bị của mình không cần admin; External Commit không đổi thành viên/vai trò) và thêm giới hạn Commit/GroupInfo 128 KiB, Welcome 3 MiB (ADR 0004).
- Giới hạn Commit/GroupInfo/Welcome là số khởi điểm, đo lại kích thước Welcome ở giai đoạn 4.
- Việc dở / giới hạn: server chưa kiểm credential External Commit (6.5 bước 6: chỉ kiểm tài khoản đã là thành viên và không đổi thành viên/vai trò); tin ephemeral chưa giới hạn 1 lần/3 giây; `leaving` (6.4) chưa có; Valkey chưa dùng; 1 tiến trình gateway (chưa đóng kết nối cũ giữa các node); `TransactWriteItems` DynamoDB Local không phản ánh hết giới hạn thật (100 mục/4 MB) nên ngưỡng 50 Welcome cần kiểm trên DynamoDB thật.
- CI `server.yml` đã xanh trên GitHub (PR #5). `dev/docker-compose.yml` vẫn chưa chạy (sandbox không có Docker).
- Cần làm tiếp: merge PR #5, rồi giai đoạn 3 (app Flutter, đăng nhập OTP/passkey, `KeyService`/`DeviceService`).
- 07/11/2026: đổi module Go thành `byo-chat/server` (ADR 0005); dòng ghi chú sinh mã ở trên dùng tên cũ. Chuyển sang phát triển local: đã cài Go, buf, plugin protoc, Flutter, wasm-pack; `docker-compose.yml` đã chạy thật, `go test ./...` qua trên Postgres, DynamoDB Local, NATS thật. Còn thiếu workload C++ của Visual Studio (chỉ cần cho desktop, giai đoạn 4).
