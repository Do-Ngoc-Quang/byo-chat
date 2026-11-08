# Hệ thống Chat (E2EE, gọi video) — hướng dẫn cho Claude Code

Một người phát triển. Trả lời tiếng Việt, ngắn, gạch đầu dòng. Code trước, chú thích 2–3 dòng mỗi đoạn.

## Nguồn sự thật (đọc trước khi code)
- `docs/spec/` — thiet-ke-chinh.md (kiến trúc), giao-thuc.md (Protobuf, luồng MLS), man-hinh.md; `docs/ui/` (giao diện HTML, là chuẩn bắt buộc cho mọi UI: xem mục "Giao diện").
- Chỗ đặt file: `docs/quy-uoc-to-chuc.md` là nguồn duy nhất. Tạo file/thư mục mới phải theo đó; đổi bố cục thì sửa quy ước và thêm ADR trong `docs/decisions/`.
- Spec giao thức là nguồn DUY NHẤT cho trường Protobuf và luồng MLS. Muốn đổi: sửa spec trước, ghi ADR vào `docs/decisions/` và `docs/notes.md`, rồi mới sửa code.
- Phạm vi đã chốt, KHÔNG mở rộng: Android, Web, desktop. iOS để sau (thiết kế giữ nguyên, không làm). Không bot, kênh, stories, thanh toán, tìm kiếm phía server.

## Giao diện (BẮT BUỘC làm đúng thiết kế)
- Mọi màn hình, widget, theme, chữ, màu, khoảng cách, bố cục phải làm GIỐNG bản vẽ trong `docs/ui/` (`Mobile-*`, `Desktop-*`, `Main.dc.html`) và `docs/spec/man-hinh.md`. Không tự nghĩ ra kiểu Material mặc định, không "làm chức năng trước, đẹp sau".
- TRƯỚC khi viết hoặc sửa UI: mở đúng file thiết kế của màn đó, trích kích thước, màu, chữ, bố cục (token chung: Inter, nền #FFFFFF, chữ #14171F, phụ #5B6270, viền #E4E6EB/#D5D8DE, nhấn #2563EB, nút pill 52px, avatar pastel). Dùng `app/lib/ui/theme.dart` (`Ui`, `ScreenScaffold`, `InfoCard`, `CodeBoxes`, `Avatar`); thiếu thì bổ sung ở đó, không rải màu cứng trong từng màn.
- Có cả bản Mobile và Desktop: làm cả hai bố cục (Desktop nhiều cột) khi tới màn tương ứng. Màn có trong thiết kế mà app chưa có thì làm theo thiết kế, không bỏ.
- SAU khi sửa UI: chạy app (Chrome/emulator/Windows), chụp màn hình và đối chiếu với thiết kế; ghi vào `docs/notes.md` điểm còn lệch. Không đánh dấu "xong" trong `docs/ke-hoach.md` nếu chưa đối chiếu hoặc còn lệch mà chưa ghi rõ.
- Cần lệch khỏi thiết kế (kỹ thuật không cho phép, thiếu dữ liệu): hỏi người dùng hoặc ghi rõ lý do ở `docs/notes.md`; thiết kế mới sửa trong `docs/ui/` trước rồi mới sửa code.

## Stack
- Client: Flutter + lõi Rust `chatcore` (OpenMLS 0.8; WASM cho Web, FFI cho mobile/desktop).
- Server: Go; WebSocket + Protobuf (`chat.v1`) + Connect RPC; NATS JetStream; Aurora PostgreSQL; DynamoDB; Valkey; Amazon S3 (ADR 0014, thay R2); LiveKit (SFrame).
- MLS: cipher suite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.

## Quy tắc bất biến (đã kiểm chứng bằng PoC, xem `docs/spec/giao-thuc.md` mục 8)
- Server chỉ chuyển ciphertext (ngoại lệ duy nhất: ảnh đại diện công khai). Ciphertext có TTL 30 ngày.
- Server từ chối `SendMessage` sai epoch (`EPOCH_MISMATCH`); client không giữ khóa epoch cũ.
- Commit và Welcome đi qua `SubmitCommit`, không qua `SendMessage`. Con trỏ hộp thư ghi qua hàng đợi bền, idempotent theo `(conv_id, seq)`.
- Thiết bị mới tự vào nhóm bằng External Commit. Khôi phục với khóa ký mới KHÔNG tự gỡ leaf cũ: thành viên online có leaf index nhỏ nhất gửi Remove.
- Giới hạn: 50 thiết bị mỗi Commit, 256 thiết bị mỗi nhóm (ADR 0011; đã hạ từ 1.000 vì Welcome/GroupInfo vượt hạn mức).
- Khóa SFrame = `Exporter("call", call_id, 32)`. Đổi khóa khi có người vào/ra; bên gửi chuyển khóa mới sau ~1 giây, bên nhận giữ khóa cũ và mới theo chỉ số khóa.
- Không tự viết primitive mật mã. Không log plaintext, khóa, ciphertext.
- Số trường Protobuf không bao giờ dùng lại; CI chạy `buf breaking`.

## Lệnh (tạo dần khi có mã)
- `proto/`: `buf lint && buf breaking --against .git#branch=main`
- `chatcore/`: `cargo test --release`; WASM: `wasm-pack build --target web`
- `server/`: `go vet ./... && go test ./...`
- `app/`: `flutter analyze && flutter test`

## Thứ tự làm (theo mục 16 của tài liệu chính)
1. Proto + CI + `chatcore` (viết lại theo spec, `poc/` đã xóa; biến ca recovery, resync, scale, exporter thành test).
2. Server tối thiểu: gateway, Message Service, hộp thư (DynamoDB local, Postgres trong Docker).
3. Lát cắt dọc: đăng nhập, chat 1-1 có E2EE trên Android và Web.
4. Nhóm, đa thiết bị, backup. 5. Media. 6. Gọi video (bắt đầu sau khi chat ổn định).
Môi trường: KHÔNG có máy thật, chỉ mô phỏng (emulator, Chrome/Node headless, CI). Mục cần máy thật là "hoãn, cần thiết bị thật": ghi rõ giới hạn của kiểm thử mô phỏng, không dùng để chặn "xong" của giai đoạn.
Chưa kiểm chứng, làm ở cổng tương ứng (cần thiết bị thật thì hoãn): MLS trên máy ARM thật, video trên Flutter Android và Safari, kích thước Welcome, Commit thêm 1 thiết bị, ngưỡng payload push FCM.

## Quy trình làm việc
- Tiến độ và checklist: `docs/ke-hoach.md` (nơi duy nhất). Đầu phiên đọc, cuối phiên tick; không theo dõi việc ở chỗ khác.
- Git: KHÔNG tự commit hay push; chỉ làm khi người dùng bảo (kể cả khi hook nhắc). "cp" = commit + push, người dùng nói "cp" thì làm cả hai. Làm từng bước nhỏ, sửa file xong thì báo.
- Git: không push vào `main`; làm trên nhánh, tạo PR vào `main` (quy ước ở `docs/quy-uoc-to-chuc.md`, mục "Quy trình git").
- Git: ĐẦU PHIÊN, trước khi sửa gì, `git fetch --all --prune` rồi tách nhánh mới từ `origin/main` mới nhất (`git switch -c <nhánh> origin/main`); không làm tiếp trên nhánh cũ đã merge. Nhánh mặc định là `main`.
- Mỗi phiên một mục tiêu nhỏ. Cuối phiên ghi quyết định và việc dở vào `docs/notes.md`; quyết định kiến trúc vào `docs/decisions/`.
- Số phiên bản tài liệu: đổi phạm vi đổi số đầu; thêm thiết kế đổi số giữa; làm rõ đổi số cuối.
- Số đo hiệu năng mốc (Windows native): 256 thiết bị, Commit cuối 22 KB, tạo 8 ms, nhận 2 ms (Welcome 48 KB). Mốc cũ ở 1.000 thiết bị: 92 KB, 33 ms, 11 ms. Android emulator chậm ~3 lần khi tạo; WASM ~5 lần. Test hiệu năng không được tệ hơn mốc đáng kể.
