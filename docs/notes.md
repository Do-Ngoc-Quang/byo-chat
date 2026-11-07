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

## Phiên giai đoạn 3, bước 1 (khung app và cầu nối, 07/11/2026)
- Nhánh `feat/app-skeleton`, chưa commit/push (chờ lệnh). ADR 0006: cầu nối chatcore sang Dart (FFI viết tay + WASM trong Web Worker).
- Đã làm: `flutter create` (Android, Web) vào `app/`; `chatcore/ffi` (cdylib) và `chatcore::version()` dùng chung với `wasm`; `ChatCore` + hai cài đặt Dart; `app.yml`.
- Đã kiểm thật: `flutter analyze` sạch; `flutter test` qua (có test FFI với dll trên Windows); `flutter build web` + Chrome (Worker nạp WASM, hiện `chatcore 0.1.0`); `flutter test integration_test` qua trên emulator Android x86_64 API 37 (`getconf PAGE_SIZE` = 16384).
- Giới hạn: mới chỉ có `version()` qua cầu nối, chưa có API MLS; chưa kiểm aarch64/ARM thật/Safari; `app.yml` chưa chạy trên GitHub; emulator có trang 16 KB nhưng chỉ x86_64, chưa phải bằng chứng cho mục "trang 16 KB" của chatcore.
- Còn thiếu cho lát cắt dọc (theo thứ tự đề xuất): (1) API MLS qua cầu nối; (2) server `AuthService` (OTP chế độ dev), `DeviceService.RegisterDevice`, `KeyService`; (3) màn đăng nhập, danh sách chat, chat 1-1 trên Android và Web; (4) passkey; (5) đo payload FCM (cần thiết bị thật: hoãn).
- Lưu ý: Gradle lần đầu mất ~8 phút (tải SDK Platform 36); `flutter create` ghi `.metadata`, `byo_chat.iml` có thể thừa, kiểm khi commit.

## Phiên giai đoạn 3, bước 2 (API MLS qua cầu nối, 07/11/2026)
- `chatcore::api::Core::call(op, packed_args)`: một hàm gọi mọi thao tác, tham số/kết quả là danh sách byte đóng gói (u32 LE độ dài + dữ liệu). `ffi` thêm `chatcore_open/call/close/buf_free` (bọc `catch_unwind`, lỗi trả chuỗi); `wasm` thêm `WasmCore`; Worker có op `open` và `call`. Dart: `ChatCore.open/callRaw` + extension `ChatCoreMls`.
- KeyPackage trao đổi dạng `MLSMessage` (kiểm chữ ký bằng `KeyPackageIn::validate`).
- Phát hiện: dart2js không hỗ trợ `ByteData.getUint64` (`Unsupported operation`), lỗi chỉ lộ khi chạy thật trên Chrome; đã đọc epoch bằng hai nửa 32 bit. Flutter không chạy `integration_test` trên Web nếu thiếu chromedriver, nên dùng `integration_test/web_smoke.dart` (in `MLS OK` lên màn hình).
- Đã kiểm: `cargo test --release` toàn bộ qua; `flutter analyze` sạch; `flutter test` (FFI Windows) 4 qua; Chrome thấy `MLS OK` (3 Worker); emulator Android x86_64: 2 test tích hợp qua.
- Giới hạn: trạng thái MLS chỉ trong bộ nhớ (chưa lưu bền, mất khi tắt app); chưa có remove/update/resync qua cầu nối; credential chỉ là byte danh tính thô (chưa có chữ ký khóa danh tính tài khoản theo 6.1); chưa dùng `Payload` protobuf; CI `app.yml` chưa chạy Android/Web smoke. Một HTTP server tĩnh (python, cổng 8138) có thể còn chạy nền từ lúc kiểm Web.

## Phiên giai đoạn 3, bước 3 (server Auth/Device/Key, 07/11/2026)
- Spec 1.1.1 (ADR 0007): credential 136 byte bố cục cố định (account_id, device_id, khóa thiết bị, created_ms, chữ ký Ed25519 của khóa danh tính lên "chat.v1.credential" + 72 byte đầu); tham số OTP (6 số, 5 phút, 5 lần sai, cách nhau 30 giây), ticket 10 phút dùng một lần, access 15 phút, refresh 30 ngày xoay vòng.
- Mã: `internal/account` (logic), `internal/api/account.go` (Connect), `store.AccountStore` + migration `0002_auth.sql`, cài đặt bộ nhớ và Postgres chạy chung hợp đồng `storetest.RunAccount` (tranh chấp: 6 thiết bị đầu tiên chỉ 1 thắng, lấy KeyPackage đồng thời không trùng, 20 lần tăng lần nhập OTP đồng thời đúng 20). `RegisterDevice` là một giao dịch: tiêu thụ ticket, so-và-đặt khóa danh tính, thêm thiết bị, KeyPackage, refresh token; thất bại thì ticket không cháy.
- Test: `go test ./...` qua trên Postgres, DynamoDB Local, NATS thật (gồm `TestAuthDeviceKeyOverConnect`: OTP -> RegisterDevice -> KeyPackage -> refresh -> ConversationService, thu hồi thiết bị chặn ngay access token đang sống). Chưa chạy `-race` cục bộ (Windows thiếu cgo); CI Linux chạy. Hợp đồng KeyPackage với chatcore: test `chatcore/tests/api.rs` khẳng định 8 byte đầu và kích thước <= 4 KiB.
- Giới hạn / việc dở: passkey còn Unimplemented; OTP chỉ gửi qua log (`CHAT_DEV_OTP=1`), chưa có SMS/email thật, chưa kiểm captcha; server chưa phân tích sâu KeyPackage MLS (chữ ký lá, khớp khóa thiết bị) nên tin client, client phải kiểm khi Fetch; `FetchKeyPackages` chưa giới hạn tốc độ (kẻ xấu rút cạn gói một lần về last resort); chưa có RPC thay last resort (xoay 90 ngày); `ListDevices`, `RevokeDevice`, `StartLink/ApproveLink/CompleteLink` để giai đoạn 4; OTP đã nhập đúng thì bị xóa nên không còn chặn `RequestOtp` kế tiếp (chấp nhận: chỉ chủ số mới làm được).
- Cần làm tiếp: client chatcore sinh khóa danh tính + credential + KeyPackage hàng loạt theo 6.1; màn đăng nhập OTP; rồi chat 1-1 đầu-cuối.

## Phiên giai đoạn 3, bước 4 (client credential, 07/11/2026)
- `chatcore::credential` (build/parse/verify, khóa danh tính xuất/nhập bằng TLS-serialize của `SignatureKeyPair`; `private()` của openmls bị khóa sau feature test-utils nên không dùng). `Core::new_device`: khóa ký thiết bị sinh mới, khóa danh tính sinh mới (thiết bị đầu) hoặc nhập từ `identity_export` (khôi phục), rồi credential ký bằng khóa danh tính và đưa làm identity của BasicCredential. Cầu nối: `chatcore_open_device`, `WasmCore.open_device`, Dart `openDevice`, `deviceCredential`, `identityExport`, `keyPackages`, `lastResortKeyPackage`, `verifyKeyPackage`.
- Vector liên ngôn ngữ: credential do Rust ký được Go chấp nhận và ngược lại (cùng file vector ở hai test).
- Phát hiện: KeyPackage last resort phải khai báo `ExtensionType::LastResort` trong capabilities của lá, nếu không `add_members` báo `UnsupportedExtension`. Gói một lần/last resort đều nhỏ hơn 4 KiB và có đúng 8 byte đầu server kiểm.
- Đã kiểm: `cargo test --release` toàn bộ qua; `go test ./internal/account` qua; `flutter test` (FFI Windows) 5 qua; Chrome `MLS OK` cho cả hai kịch bản; emulator Android x86_64 3 test tích hợp qua.
- Giới hạn: khóa danh tính và khóa thiết bị chỉ ở bộ nhớ (chưa keystore, chưa lưu bền trạng thái MLS: tắt app là mất); `created_ms` do app truyền vào (đồng hồ máy), server chưa kiểm lệch giờ; chưa gọi thật server từ Dart (chưa có client Connect trong app); `verify_key_package` kiểm chữ ký gói + credential + khớp khóa thiết bị nhưng chưa kiểm hạn `Lifetime` của gói và chưa so khóa danh tính với lần đã thấy (TOFU, 6.2 bước 2).
- Cần làm tiếp: client Connect (Dart) + màn đăng nhập OTP gọi server thật; lưu bền khóa/trạng thái (keystore, SQLCipher/OPFS); TOFU khóa danh tính.

## Phiên giai đoạn 3, bước 5 (client Connect + OTP, 07/11/2026)
- Dart: mã sinh bằng `buf generate` (plugin remote BSR chạy được khi có mạng) vào `app/lib/gen/` (đổi từ `app/gen/` để import bằng `package:`; thêm `proto/buf.gen.app.yaml` cho CI). `ConnectClient` (Connect unary, `application/proto`, phân tích lỗi JSON + `chat.v1.Error` trong details), `ChatApi`, `LoginController`, `LoginPage`, `HomePage`, UUIDv7.
- Server: CORS theo danh sách origin (`CHAT_CORS_ORIGINS`, mặc định tắt) vì app Web khác origin; `CHAT_DEV_OTP_CODE` mã OTP cố định cho e2e (chỉ khi `CHAT_DEV_OTP=1`).
- Kiểm thật với server Go thật + Postgres/DynamoDB/NATS thật: kịch bản `runLoginE2E` (mã sai bị từ chối, đăng nhập, 100 gói trên server, Fetch rồi `verifyKeyPackage` trong lõi, refresh xoay vòng, đăng nhập lại cùng số bị chặn) qua trên FFI Windows, emulator Android (HTTP tới 10.0.2.2, chỉ bật cho bản debug), Chrome (thấy OPTIONS 204 rồi POST). Test đơn vị với máy chủ giả: 7 test (luồng, lỗi, rate limit, tài khoản đã có, thử lại sau lỗi tạm thời, UUIDv7, màn hình).
- Giới hạn: khóa và phiên chỉ ở bộ nhớ (tắt app là về màn đăng nhập, và vì thiết bị mất khóa danh tính nên đăng nhập lại cùng số sẽ bị chặn tới khi có liên kết/khôi phục: mỗi lần chạy e2e dùng số mới); không tự refresh token khi hết hạn; chưa có WebSocket trong app; chưa có HTTPS (dev dùng HTTP); chưa chống bấm liên tiếp ngoài cờ `busy`; `lib/gen` cần sinh trước khi analyze/test.
- Cần làm tiếp: lưu bền khóa/trạng thái; danh sách chat + chat 1-1 qua WebSocket (CreateConversation, Welcome, SendMessage).

## Phiên giai đoạn 3, bước 6 (lưu bền khóa, 07/11/2026)
- ADR 0008. chatcore: `MemoryStorage.values` của openmls là `pub` nên snapshot/khôi phục không cần feature test-utils; khôi phục dựng lại signer bằng `SignatureKeyPair::read`, nhóm bằng `MlsGroup::load`. Test `tests/persist.rs`: khởi động lại giữa cuộc trò chuyện (ratchet đúng), KeyPackage/last resort sinh TRƯỚC khi tắt app vẫn dùng để vào nhóm (cần khóa init riêng đã lưu), credential và khóa danh tính giữ nguyên, sai khóa/sửa bất kỳ byte/cắt cụt/sai phiên bản đều bị từ chối, snapshot không chứa khóa ở dạng rõ, nonce khác nhau mỗi lần.
- App: `SessionStore` (ghi snapshot rồi metadata; khôi phục có làm mới token, dọn sạch khi hỏng/bị thu hồi, offline vẫn vào), `LoginController` ghi bền TRƯỚC khi báo đã đăng nhập (server đã tiêu thụ ticket), khôi phục khi mở app, nút đăng xuất. 9 test đơn vị mới với kho bộ nhớ và server giả.
- Kiểm thật: `persist_e2e` (đăng nhập thật, tạo nhóm, tắt lõi, mở lại chỉ bằng kho: nhóm còn nguyên, vào nhóm của người khác bằng KeyPackage đã tải lên trước đó, token gọi được server) qua trên FFI Windows (kho tệp), emulator Android (Keystore thật + tệp thật), Chrome (localStorage + flutter_secure_storage web). `cargo test --release` toàn bộ qua; `flutter analyze` sạch.
- Giới hạn: snapshot ghi cả trạng thái mỗi lần; Web localStorage ~5 MB và khóa cùng origin (không chống XSS); chưa có cơ chế tự động gọi `save` sau mỗi thao tác MLS (chưa có thao tác nào ngoài đăng ký, việc của bước chat); chưa kiểm xóa dữ liệu app/Keystore bị mất; chưa tự refresh token khi chạy lâu (chỉ khi mở app); `app.yml` chưa chạy trên GitHub kể từ khi thêm gói lưu trữ (cần `buf generate` và có thể cần cấu hình Android).
- Cần làm tiếp: chat 1-1 qua WebSocket (ListConversations, CreateConversation + Welcome, SendMessage/Deliver, giải mã, hộp thư cục bộ), gọi `SessionStore.save` sau mỗi thay đổi MLS.

## Phiên giai đoạn 3, bước 7 (chat 1-1 WebSocket, 07/11/2026)
- ADR 0009. chatcore: `padding_size(256)`, op `rename_group`, `drop_group`, `group_members`, `app_state_set/get`; snapshot v2 mang `app_state`. MLS đệm cả khung và chữ ký (~70 byte) nên bậc 256 byte đầu chứa nội dung tới ~180 byte (test `chat_support.rs`).
- Server: `ProfileService.LookupAccount` (`AccountByContact` ở kho, giới hạn 30/giờ theo tài khoản, bộ nhớ trong tiến trình: nhiều node cần Valkey); `OriginPatterns` cho WebSocket (phát hiện khi chạy Chrome: `websocket.Accept` mặc định từ chối khác origin, 403, không thấy request nào ở tab mạng); spec 1.1.2.
- App: `GatewayClient`, `ChatEngine`, `LocalDoc`, `ConversationsPage`, `ChatPage`, mutex bất đồng bộ cho mọi thay đổi trạng thái; `SessionStore.namespace` để nhiều phiên trong một kho (test).
- Kiểm thật (server Go thật + Postgres/DynamoDB/NATS thật): `runChatE2E` hai thiết bị: Welcome live, 3 tin liên tiếp đúng thứ tự, trả lời, mở trùng không tạo hội thoại thứ hai (`existed`/có sẵn), Bob tắt app + Alice gửi + Bob mở lại nhận đúng một lần, lịch sử còn, gửi tiếp sau khôi phục (ratchet đúng), khoảng trống seq ép bằng cách lùi `lastSeq` rồi lấp bằng FetchLog, tin gửi lúc gateway chưa sẵn sàng được gửi khi online. Qua trên FFI Windows (3 giây), emulator Android (11 giây), Chrome. `go test ./...` toàn bộ, `cargo test --release`, `flutter test` (23) qua. Giao diện thật trên Chrome: đăng nhập OTP, "Đã kết nối", danh sách trống, hộp thoại chat mới.
- Giới hạn: kiểm chưa phủ giao diện chat thật hai người (e2e chạy ở tầng engine); kho ghi lại toàn bộ mỗi lần; chưa gửi DeliveredReceipt/ReadUpTo; giải mã lỗi mới chỉ có chỗ giữ chỗ; tài khoản đã có vẫn không vào lại được (cần liên kết/khôi phục, giai đoạn 4) nên đăng xuất là mất hội thoại; không tự làm mới token giữa phiên (chỉ khi mở app hoặc đóng 4002 thì gateway gọi làm mới); trong lần thử snackbar trên Chrome nhập số bằng tay bị sai (lỗi thao tác kiểm thử, hiện lỗi INVALID_ARGUMENT đúng); `app.yml` chưa chạy trên GitHub.
- Cần làm tiếp (hết lát cắt dọc ngoại trừ đo FCM cần máy thật): chạy `app.yml` trên GitHub và thêm job Android; kiểm lại cổng giai đoạn 3 với người dùng; passkey; sau đó giai đoạn 4 (nhóm, đa thiết bị, liên kết/khôi phục).
