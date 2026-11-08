# Thiết kế hệ thống Chat đa nền tảng: E2EE và gọi video

Nov 3, 2026 · @Quang

**Phiên bản:** 1.4.0

## 1. Tóm tắt điều hành

Hệ thống dùng một lõi Rust chung cho mã hóa và đồng bộ, backend Go trên Kubernetes và LiveKit cho gọi video. Server chỉ chuyển ciphertext, nên một người vẫn vận hành được và hệ thống mở rộng ngang không có trần cố định.

Các quyết định chính:

- **Client:** Flutter cho Android, Web và desktop (iOS để sau) (macOS, Windows, Linux), cùng lõi Rust (Messaging Layer Security (MLS), SQLite mã hóa, đồng bộ) nối qua flutter\_rust\_bridge.
- **E2EE** (End-to-End Encryption)**:** MLS (RFC 9420) cho mọi hội thoại, kể cả 1-1 (nhóm 2 người). Một giao thức duy nhất cho 1-1, nhóm và đa thiết bị.
- **Realtime:** WebSocket + Protocol Buffers (Protobuf). Backend Go dạng modular monolith, tách dịch vụ khi cần. NATS JetStream làm bus sự kiện và định tuyến.
- **Lưu trữ:** PostgreSQL cho metadata (khóa shard `account_id`), DynamoDB cho hộp thư ciphertext có Time To Live (TTL), Redis/Valkey cho presence và rate limit.
- **Gọi video:** LiveKit tự host trên Kubernetes, E2EE bằng Secure Frame (SFrame) với khóa lấy từ MLS exporter.
- **Vận hành:** dùng dịch vụ managed cho mọi thứ ngoài lõi sản phẩm; hạ tầng khai báo bằng Terraform.

Hệ thống chưa được kiểm chứng bằng thực nghiệm. Mục 16 liệt kê các Proof of Concept (PoC) cần làm trước khi cam kết toàn bộ stack. Ước lượng thô: khoảng 12 tháng làm toàn thời gian cho một người, nếu giữ kỷ luật phạm vi.

## 2. Yêu cầu và phạm vi

MVP gồm chat 1-1 và nhóm có E2EE trên ba nền tảng (Android, Web, desktop; iOS để sau), kèm gọi thoại/video. Các tính năng cần server hiểu nội dung (tìm kiếm phía server, bot, kênh phát sóng lớn) nằm ngoài giai đoạn đầu.

**Chức năng**

- Chat 1-1 và nhóm (thiết kế cho nhóm hàng nghìn người nhờ MLS).
- Gửi text, ảnh, video, file, voice message; trả lời, reaction, sửa và xóa tin.
- Trạng thái đã gửi, đã nhận, đã xem; đang gõ; online/offline.
- Một tài khoản dùng đồng thời trên nhiều thiết bị (điện thoại, web, desktop).
- Push notification khi app đóng; nhận tin tồn đọng khi online lại.
- Tìm kiếm lịch sử chat (chạy trên thiết bị).
- Gọi thoại và video 1-1 và nhóm, có E2EE.

**Phi chức năng**

| Tiêu chí | Mục tiêu |
| --- | --- |
| Độ trễ gửi-nhận cùng vùng | p95 dưới 200 ms |
| Độ tin cậy | Không mất, không trùng, đúng thứ tự trong một hội thoại |
| Sẵn sàng | 99,95% cho gateway và hộp thư |
| Mở rộng | Ngang ở mọi tầng, không thành phần đơn lẻ nào giới hạn quy mô |
| Bảo mật | E2EE mặc định, Transport Layer Security (TLS) 1.3, forward secrecy, post-compromise security |
| Dữ liệu trên server | Ciphertext, xóa khi mọi thiết bị đã nhận hoặc sau TTL 30 ngày |
| Gọi video | Trễ mouth-to-ear p95 dưới 400 ms trong cùng vùng |

Các mục tiêu trên là mục tiêu thiết kế, cần xác nhận bằng đo đạc ở giai đoạn PoC.

**Ngoài phạm vi giai đoạn đầu:** bot và Application Programming Interface (API) mở, kênh phát sóng hàng trăm nghìn người, stories, thanh toán, SSO doanh nghiệp, tìm kiếm phía server.

## 3. Nguyên tắc thiết kế

Ba ràng buộc (một người làm, scale không giới hạn, E2EE kèm video) quy về tám nguyên tắc sau.

1. **Server là người đưa thư mù.** Server chỉ thấy ciphertext và metadata định tuyến, nên code backend đơn giản và ít rủi ro pháp lý về nội dung.
2. **Shard được theo khóa từ ngày đầu.** ID phân tán (Universally Unique Identifier phiên bản 7, UUIDv7), không auto-increment; mọi bảng có `account_id` hoặc `conv_id` làm khóa phân vùng.
3. **Lưu tạm, không lưu vĩnh viễn.** Ciphertext trên server có TTL. Lịch sử nằm trên thiết bị và trong backup mà người dùng giữ khóa. Chi phí lưu trữ không tăng theo thời gian.
4. **Không tự viết mật mã, không tự viết media server.** Dùng MLS (OpenMLS) và LiveKit; thuê audit độc lập trước khi công khai.
5. **Mua thay vì xây ở mọi thứ ngoài lõi.** Database, cache, Content Delivery Network (CDN), One-Time Password (OTP), giám sát đều dùng dịch vụ managed.
6. **Offline-first.** UI luôn đọc từ DB cục bộ; mạng chỉ làm nhiệm vụ đồng bộ.
7. **Mọi thao tác idempotent.** Gửi lại không tạo tin trùng nhờ `client_msg_id`.
8. **Tối giản vận hành.** Ít loại dịch vụ, một ngôn ngữ backend, tách microservice chỉ khi có số liệu chứng minh.

## 4. Kiến trúc tổng thể

Hệ thống gồm client, backend Go và kho dữ liệu, cộng một mặt phẳng media riêng cho gọi video. Server chỉ xử lý ciphertext và metadata định tuyến.

&#91;embedded content: kiến trúc tổng thể · 3 tầng + mặt phẳng media\]

Client nói chuyện với server qua hai đường: HTTPS (Connect RPC) đi qua Cloudflare, WebSocket đi qua Network Load Balancer (NLB). Tin nhắn chạy từ Gateway sang Message Service rồi ra NATS và kho dữ liệu; cuộc gọi dùng đường riêng tới LiveKit.

**Vai trò các thành phần**

- **Gateway WS:** giữ kết nối WebSocket, xác thực, giới hạn tốc độ, đăng ký NATS theo thiết bị và đẩy tin xuống. Không giữ trạng thái nghiệp vụ.
- **Message Service:** khử trùng, cấp `seq`, ghi `conv_log` và hộp thư, phát sự kiện lên NATS.
- **API:** Connect RPC cho đăng nhập, thiết bị, KeyPackage, nhóm, media, backup, và cấp token cuộc gọi.
- **Push worker:** nhận sự kiện thiết bị offline và gửi Firebase Cloud Messaging (FCM), Apple Push Notification service (APNs), Web Push.
- **NATS JetStream:** định tuyến tới đúng gateway đang giữ thiết bị, và hàng đợi bền cho sự kiện.
- **LiveKit:** Selective Forwarding Unit (SFU) và Traversal Using Relays around NAT (TURN) cho cuộc gọi; chỉ thấy gói media đã mã hóa bằng SFrame.

## 5. Stack công nghệ chốt

Stack chọn các thành phần mạnh, phổ biến và có cộng đồng lớn, sao cho một người nắm được toàn bộ: Rust ở client, Go ở server, Protobuf nối hai bên.

| Tầng | Lựa chọn | Lý do chính | Phương án thay thế |
| --- | --- | --- | --- |
| UI client | Flutter 3 (Dart): Android, Web, macOS, Windows, Linux (iOS để sau) | Một codebase UI cho ba nền tảng; có SDK LiveKit | React Native + React web |
| Lõi dùng chung | Rust: OpenMLS, rusqlite + SQLCipher, tokio, prost | Mật mã, đồng bộ, DB cục bộ viết một lần | Kotlin Multiplatform |
| Cầu nối | flutter\_rust\_bridge (native và WebAssembly (WASM)) | Binding tự sinh cho Dart | UniFFI |
| Backend | Go: gateway WebSocket, API, worker | Goroutine rẻ, một binary tĩnh, NATS và LiveKit đều viết bằng Go | Elixir/Phoenix, Rust |
| Giao thức | Protobuf (quản lý bằng buf) qua WebSocket nhị phân; Connect RPC cho API đơn | Một file .proto sinh code cho Dart, Rust, Go | gRPC thuần |
| Bus và định tuyến | NATS JetStream | Subject theo thiết bị, hàng triệu subscription, vận hành nhẹ | Kafka (MSK) |
| Metadata | PostgreSQL (Aurora), khóa shard `account_id`, nâng lên Citus khi cần | Quan hệ, giao dịch, ecosystem lớn | CockroachDB |
| Hộp thư ciphertext | DynamoDB on-demand, TTL có sẵn | Scale tự động, độ trễ ổn định, TTL xóa dữ liệu miễn phí | ScyllaDB Cloud |
| Cache và presence | Valkey/Redis cluster (ElastiCache) | TTL, rate limit, pub/sub nhẹ | KeyDB, Dragonfly |
| Media | Amazon S3 (CloudFront khi cần), upload qua presigned URL | Cùng AWS với phần còn lại, IAM role thay khóa API, lifecycle và SSE-KMS sẵn có (ADR 0014) | Cloudflare R2 (không phí egress) |
| Push | FCM HTTP v1, APNs HTTP/2, Web Push (VAPID), gọi từ push worker | Không phụ thuộc bên thứ ba cho token | OneSignal |
| Gọi video | LiveKit (SFU + TURN nhúng), tự host trên Kubernetes | SFU mã nguồn mở, SDK đủ nền tảng, hỗ trợ E2EE | LiveKit Cloud ở giai đoạn đầu |
| Xác thực | OTP (Twilio Verify) + passkey (WebAuthn); token Platform-Agnostic Security Tokens (PASETO) ngắn hạn gắn với thiết bị | Không lưu mật khẩu; khóa E2EE tách khỏi đăng nhập | Firebase Auth |
| Hạ tầng | Amazon Web Services (AWS): Elastic Kubernetes Service (EKS) (Karpenter), NLB cho WebSocket, Terraform, Argo CD | Autoscale, hạ tầng khai báo | GKE, Fly.io |
| Biên mạng | Cloudflare: DNS, Web Application Firewall (WAF), DDoS, Turnstile | Bảo vệ API và chống bot | AWS WAF + Shield |
| Quan sát | OpenTelemetry, Grafana Cloud, Sentry (client), PagerDuty | Trace theo `message_id`, cảnh báo | Datadog |
| Continuous Integration / Continuous Delivery (CI/CD) | GitHub Actions, Fastlane (mobile), buf CI | Phát hành ba nền tảng từ một repo | GitLab CI |

**Vì sao Go cho backend.** Với E2EE, server không xử lý nội dung nên phần khó nhất là giữ hàng trăm nghìn kết nối và chuyển tiếp nhanh. Go làm tốt việc này, ít khái niệm hơn Elixir và dễ học hơn Rust khi bạn đã dùng Rust ở client.

**Vì sao Flutter.** Ưu tiên lớn nhất cho một người là một codebase UI duy nhất. Phần native bắt buộc (CallKit/PushKit, Notification Service Extension (NSE) giải mã trên iOS, dịch vụ nhận push trên Android) chỉ là lớp Swift/Kotlin mỏng gọi vào lõi Rust.

**Rủi ro khóa nhà cung cấp.** DynamoDB và Aurora gắn với AWS. Giảm bằng cách đặt sau interface lưu trữ trong Go (`MailboxStore`, `MetaStore`) để có thể đổi sang ScyllaDB và CockroachDB.

## 6. Client đa nền tảng

UI Flutter chỉ là lớp mỏng. Toàn bộ logic nhạy cảm (MLS, quản lý khóa, DB cục bộ, đồng bộ, tìm kiếm) nằm trong một crate Rust tên `chatcore`, biên dịch cho cả ba nền tảng (iOS để sau).

**Các module của `chatcore`**

- `crypto`: MLS qua OpenMLS, quản lý KeyPackage, mã hóa media.
- `store`: SQLite + SQLCipher (lịch sử, outbox, trạng thái nhóm MLS), Full-Text Search 5 (FTS5) cho tìm kiếm.
- `net`: client WebSocket, heartbeat, reconnect.
- `sync`: con trỏ `last_seq` theo hội thoại, nhận hộp thư, gửi lại outbox.

**Khác biệt theo nền tảng**

| Nền tảng | Chạy lõi Rust bằng | Nơi giữ khóa | Phần native bắt buộc |
| --- | --- | --- | --- |
| iOS | Thư viện tĩnh qua FFI | Keychain (khóa bọc khóa DB, dùng chung với extension qua app group) | CallKit, PushKit, Notification Service Extension để giải mã push |
| Android | `.so` qua FFI | Android Keystore (StrongBox nếu có) | Dịch vụ nhận FCM data message, ConnectionService hoặc full-screen intent cho cuộc gọi |
| Web | WASM trong Web Worker | Khóa WebCrypto không xuất được + Origin Private File System (OPFS) | Service Worker cho Web Push |
| Desktop | Thư viện native | Keychain, DPAPI, libsecret | Tray, thông báo hệ điều hành, tự khởi động |

**Hành vi chung**

- **Offline-first.** UI đọc từ SQLite qua stream. Gửi tin = ghi vào outbox ở trạng thái đang gửi, worker mã hóa rồi gửi, Acknowledgement (ACK) của server cập nhật trạng thái.
- **Kết nối.** WebSocket nhị phân, heartbeat 25 giây, reconnect với exponential backoff và jitter. Nếu mạng chặn WebSocket thì chuyển sang HTTP streaming.
- **Đồng bộ.** Mỗi thiết bị giữ con trỏ hộp thư riêng và `last_seq` theo từng hội thoại, nên thiết bị mất kết nối lâu chỉ kéo phần còn thiếu.
- **Landing page tách riêng.** Flutter Web không phù hợp SEO, nên trang giới thiệu dùng framework tĩnh (ví dụ Astro) còn app web chạy ở tên miền con.

## 7. Giao thức và API

Hai kênh dùng chung một bộ file `.proto`: WebSocket nhị phân cho dữ liệu realtime, Connect RPC (HTTP/1.1 và HTTP/2) cho thao tác đơn lẻ như đăng nhập, lấy khóa, xin URL upload.

Định nghĩa đầy đủ của `ClientFrame`, `ServerFrame` (gồm khung `IncomingCall`) và các dịch vụ nằm trong tài liệu "Đặc tả giao thức và luồng MLS cho hệ thống Chat" (bản 1.0.0), là nguồn duy nhất cho các trường Protobuf. Tài liệu này chỉ giữ danh sách dịch vụ và các quy ước bên dưới.

**Dịch vụ Connect RPC**

| Dịch vụ | Chức năng |
| --- | --- |
| AuthService | Gửi và xác minh OTP, passkey, cấp và làm mới token |
| DeviceService | Đăng ký thiết bị, liên kết thiết bị mới, thu hồi |
| KeyService | Tải lên KeyPackage, lấy KeyPackage của thiết bị khác |
| ConversationService | Tạo nhóm, gửi Commit và Welcome của MLS, rời nhóm |
| MediaService | Cấp presigned URL upload và download |
| CallService | Tạo phòng, cấp token LiveKit sau khi kiểm tra quyền |
| PushService | Đăng ký và hủy token FCM, APNs, Web Push |
| BackupService | Lưu và lấy blob backup đã mã hóa |
| ProfileService | Tên và ảnh đại diện, tra cứu tài khoản theo số điện thoại hoặc email |
| BlockService | Chặn, bỏ chặn và liệt kê người đã chặn |

**Quy ước**

- Số hiệu trường Protobuf không bao giờ dùng lại; CI chạy `buf breaking` để chặn thay đổi gây vỡ tương thích.
- Client báo `proto_version` khi `Hello`; server hỗ trợ ít nhất hai phiên bản gần nhất để app cũ vẫn chạy trong lúc người dùng chưa cập nhật.
- Tắt nén WebSocket cho payload ciphertext (không nén được), gom nhiều frame nhỏ khi gửi liên tiếp.

## 8. Luồng tin nhắn, hộp thư, presence và push

Server ghi ciphertext vào kho bền trước, rồi mới báo cho gateway, nên mất kết nối hay sập một node không làm mất tin. Một tin MLS chỉ mã hóa một lần cho cả nhóm, nên ciphertext được lưu một bản trong `conv_log`, còn mỗi thiết bị có một hộp thư chứa con trỏ tới bản đó.

**Gửi tin**

1. `chatcore` mã hóa tin bằng MLS, ghi vào outbox và gửi `SendMessage{conv_id, client_msg_id, ciphertext}` qua WebSocket.
2. Gateway kiểm tra token, tư cách thành viên (cache Valkey) và giới hạn tốc độ.
3. Message Service khử trùng theo `(conv_id, client_msg_id)` bằng ghi có điều kiện, từ chối bằng EPOCH\_MISMATCH nếu epoch của tin khác epoch hiện tại của nhóm (nên client không cần giữ khóa của các epoch trước), rồi cấp `seq` bằng bộ đếm nguyên tử của hội thoại trong DynamoDB.
4. Ghi ciphertext vào `conv_log`, sau đó ghi hàng loạt một con trỏ vào hộp thư của từng thiết bị đích (gồm cả thiết bị khác của người gửi). Mọi item có TTL. Con trỏ hộp thư được ghi ngay sau giao dịch qua hàng đợi bền (JetStream), idempotent theo (conv\_id, seq); Commit và Welcome của MLS đi qua RPC SubmitCommit chứ không qua SendMessage.
5. Trả `SendResult{message_id, seq}` cho người gửi: trạng thái đã gửi.
6. Publish lên NATS subject `dev.<device_id>` kèm ciphertext. Gateway đang giữ kết nối của thiết bị đó đẩy `Deliver` xuống.
7. Thiết bị giải mã, lưu DB rồi gửi `Ack{inbox_id}`. Server xóa con trỏ và báo trạng thái đã nhận cho người gửi.

**Thiết bị offline.** Nếu sau khoảng 2 giây không có ack hoặc không có subscriber, push worker gửi push. Khi kết nối lại, thiết bị gửi `Hello{inbox_cursor}` và server trả phần tồn đọng theo thứ tự `inbox_id`, đọc ciphertext từ `conv_log`.

**Nhóm lớn.** Tới khoảng 2.000 thiết bị mỗi nhóm dùng cách trên (mỗi tin ghi 1 bản ciphertext + N con trỏ nhỏ). Vượt ngưỡng đó chuyển sang chế độ kéo: không ghi con trỏ, thiết bị so `head_seq` của hội thoại với con trỏ của mình. Ngưỡng này cần đo thực tế.

**Thứ tự và độ tin cậy.** Giao nhận at-least-once, client khử trùng theo `message_id`. Thứ tự theo `seq` của hội thoại; tin đến lệch thứ tự được giữ vài giây chờ khoảng trống, quá hạn thì gọi đồng bộ.

**Trạng thái đã xem và typing.** Đã xem gửi dưới dạng tin điều khiển được mã hóa MLS, nên server không biết ai đã xem gì. Typing là sự kiện tạm, mã hóa, chỉ chuyển qua NATS cho thiết bị đang online, không ghi hộp thư, giới hạn 1 lần mỗi 3 giây.

**Presence.** Heartbeat ghi khóa `presence:<account_id>` trong Valkey với TTL 60 giây. Chỉ phát thay đổi cho người đang xem liên hệ đó (subscribe theo nhu cầu), không có presence trong nhóm lớn, và người dùng có thể tắt hiển thị lần cuối online.

**Push.** Payload không chứa plaintext. Ciphertext nhỏ có thể đi kèm để iOS Notification Service Extension và dịch vụ Android giải mã cục bộ; ciphertext lớn thì push chỉ là tín hiệu và app kéo nội dung về. Extension bị giới hạn bộ nhớ và thời gian, nên chỉ nạp phần tối thiểu của `chatcore`.

## 9. E2EE với MLS

Mọi hội thoại dùng MLS (RFC 9420) qua OpenMLS trong `chatcore`. Server đóng vai Delivery Service (xếp thứ tự Commit, chuyển tin) và Authentication Service (gắn thiết bị với tài khoản), và không bao giờ giữ khóa giải mã.

**Vì sao MLS thay vì Signal Protocol**

- Một giao thức cho cả 1-1 (nhóm 2 người), nhóm và đa thiết bị, vì mỗi thiết bị là một lá của cây khóa. Chỉ có một đường code mật mã để kiểm thử và audit.
- Tin mã hóa một lần cho cả nhóm, nên server lưu một bản ciphertext thay vì N bản.
- Có forward secrecy và post-compromise security cho nhóm; chi phí cập nhật khóa tăng theo log của số thành viên.
- Đánh đổi: MLS mới hơn Signal, hệ sinh thái nhỏ hơn, cần Delivery Service xếp thứ tự Commit, và thiết bị offline quá lâu phải vào lại nhóm.

Mình chưa kiểm chứng được trạng thái hiện tại của các thư viện (hỗ trợ WASM, độ ổn định, giấy phép), nên đây là PoC bắt buộc ở mục 16. Phương án dự phòng là libsignal cho 1-1 và Sender Keys cho nhóm.

**Key directory (KeyService)**

- Mỗi thiết bị tải lên KeyPackage dùng một lần và một KeyPackage "last resort". Client tự nạp thêm khi số còn lại xuống dưới ngưỡng (ví dụ dưới 20 thì nạp 100).
- Cipher suite mặc định: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`. Phiên bản suite nằm trong metadata để đổi được sau này.

**Delivery Service.** Server chỉ nhận Commit nếu `epoch` khớp epoch hiện tại của nhóm (ghi có điều kiện vào DynamoDB). Nếu bị từ chối, client tải Commit mới, áp dụng rồi gửi lại. Server giữ bản sao bảng vai trò theo tài khoản để kiểm tra quyền thêm, gỡ thành viên và đổi vai trò; với External Commit (là PublicMessage) server đọc được lá mới và kiểm tra credential của nó được khóa danh tính tài khoản ký đúng.

**Xác thực danh tính**

- Credential của mỗi thiết bị là một khóa ký, được ký bởi khóa danh tính của tài khoản. Khóa danh tính này được tạo trên thiết bị đầu tiên.
- Người dùng không phải làm bước xác minh nào: giao diện không có màn hình xác minh khóa, safety number hay mã QR để đối chiếu, và cũng không có cảnh báo khi danh tính của người kia đổi. E2EE chạy ngầm, hoàn toàn ẩn với người dùng cuối.
- Giai đoạn 4: thêm nhật ký minh bạch khóa (Key Transparency) để phát hiện server chèn thiết bị giả. Cơ chế này cũng chạy ngầm, không hiện lên giao diện.

**Hệ quả thiết kế**

- **Tìm kiếm** chỉ chạy trên thiết bị (SQLite FTS5). Không có chỉ mục phía server.
- **Metadata vẫn lộ.** Server thấy ai nhắn ai, khi nào, kích thước tin. Sealed sender giảm bớt một phần, để giai đoạn sau.
- **Mật mã hậu lượng tử.** Theo dõi các cipher suite lai (hybrid) của MLS; thiết kế sẵn khả năng đổi suite.

## 10. Nhóm, đa thiết bị, backup

Mỗi thiết bị là một thành viên MLS độc lập. Thêm hoặc gỡ thiết bị chính là Add hoặc Remove Commit trong mọi nhóm của tài khoản đó.

**Đa thiết bị**

- **Liên kết thiết bị mới:** quét QR từ thiết bị đã tin cậy; thiết bị cũ ký credential cho thiết bị mới.
- **Chi phí:** thiết bị mới tự vào từng nhóm bằng External Commit (mục 6.5 của đặc tả giao thức), nên thiết bị cũ không cần online sau bước liên kết; ưu tiên hội thoại gần đây, các hội thoại còn lại vào lười (lazy) khi có hoạt động.
- **Thu hồi thiết bị:** gỡ khỏi tất cả nhóm bằng Remove Commit và xóa session ở server.
- **Thiết bị offline quá lâu:** bỏ lỡ Commit, nên vào lại nhóm bằng External Commit dựa trên GroupInfo mới nhất lưu ở server.

**Quyền trong nhóm**

- Vai trò (chủ nhóm, quản trị, thành viên) lưu trong group context extension và **client tự kiểm tra** mọi Commit theo chính sách này. Server chặn thêm một lớp ở API, nhưng không phải nơi duy nhất thi hành.
- Chính sách tin tự hủy cũng nằm trong group context và do client thi hành.

**Lịch sử cho thiết bị mới.** Mặc định thiết bị mới không đọc được tin cũ. Có hai cách:

1. **Chuyển trực tiếp** từ thiết bị cũ: gói lịch sử, mã hóa bằng khóa tạm trao đổi qua QR, gửi qua relay mã hóa.
2. **Backup mã hóa:** client tạo recovery key 256 bit ngẫu nhiên (hiển thị dạng chuỗi dễ chép), mã hóa snapshot DB theo từng khối bằng Advanced Encryption Standard 256 bit, chế độ Galois/Counter (AES-256-GCM) với khóa dẫn xuất HMAC-based Key Derivation Function (HKDF), rồi upload lên S3 qua BackupService. Tùy chọn thêm passphrase với Argon2id. Server không giải mã được.

Mất hết thiết bị và quên recovery key đồng nghĩa mất lịch sử. UI phải nói rõ điều này khi bật backup.

## 11. Media mã hóa

Client mã hóa file trước khi upload, nên S3 và CDN chỉ thấy blob ngẫu nhiên. Vì server không thấy nội dung, mọi xử lý ảnh và video (nén, thumbnail) diễn ra ở client.

1. Client sinh khóa ngẫu nhiên 256 bit cho từng file và mã hóa theo khối bằng AES-256-GCM (mỗi khối một nonce, khối cuối được đánh dấu), để vừa stream vừa resume được.
2. Client nén trước khi mã hóa: ảnh đổi kích thước và định dạng, video hạ độ phân giải bằng bộ mã hóa phần cứng, voice message dùng Opus.
3. Client xin presigned URL từ MediaService, upload thẳng lên S3 (multipart cho file lớn, resume theo khối).
4. Thumbnail nhỏ và blurhash được mã hóa riêng và đính kèm trong tin.
5. Tin MLS chứa `media_id`, khóa, tiền tố nonce, hash SHA-256 của ciphertext, kích thước, loại tệp và thumbnail.
6. Người nhận tải qua CDN bằng URL ký có hạn ngắn, kiểm tra hash, giải mã và lưu vào bộ nhớ cục bộ.

**Vòng đời.** Quy tắc lifecycle của S3 xóa media sau 30 ngày kể từ lúc upload, cùng thời hạn với TTL ciphertext. Người dùng giữ bản cục bộ và, nếu bật, trong backup. Media là khoản chi lớn nhất của hệ thống, nên giới hạn kích thước tệp cần được đặt từ đầu (giá trị ban đầu sẽ chốt theo chi phí đo được).

## 12. Gọi thoại và video

Mọi cuộc gọi (1-1 và nhóm) đi qua LiveKit SFU và được mã hóa đầu cuối bằng SFrame, với khóa lấy từ MLS. SFU chỉ chuyển tiếp gói media đã mã hóa, không giải mã được.

**Quyết định chính**

- **SFU cho cả 1-1.** Một đường code duy nhất; chuyển từ 1-1 sang nhóm không cần đàm phán lại. Đánh đổi là tốn băng thông server hơn P2P; có thể thêm P2P cho 1-1 sau khi chi phí đủ lớn để đáng làm.
- **Giai đoạn đầu dùng LiveKit Cloud**, chuyển sang tự host khi chi phí băng thông vượt ngưỡng đã định.
- **Giới hạn ban đầu:** số người tham gia và độ phân giải được cố định thấp rồi tăng dần theo số liệu chi phí.

**Luồng cuộc gọi**

1. Người gọi gọi `CallService.StartCall(conv_id, loại)`. Server tạo `call_id` và phòng LiveKit, cấp token cho người gọi. Việc có cuộc gọi là metadata mà server biết, giống mọi ứng dụng E2EE khác, vì server cần nó để đánh thức thiết bị.
2. Server gửi Voice over IP (VoIP) push (PushKit trên iOS) hoặc FCM ưu tiên cao (Android) tới các thiết bị của người nhận.
3. Người nhận chấp nhận, gọi `JoinCall(call_id)` và nhận token LiveKit.
4. Mỗi thành viên dẫn xuất khóa SFrame từ MLS exporter của hội thoại, gắn với `call_id`: `Exporter("call", call_id, 32)`. Khi epoch đổi giữa cuộc gọi (có người vào hoặc ra), tạo khóa mới và đặt chỉ số khóa tiếp theo. Bên gửi chuyển sang khóa mới sau khi gửi xong Commit khoảng 1 giây, bên nhận giữ cả khóa cũ và khóa mới theo chỉ số khóa, nên không mất tiếng khi đổi khóa (PoC đo 0 giây mất tiếng).

Cuộc gọi chỉ gồm một tập con của nhóm cần một nhóm MLS riêng cho cuộc gọi đó; đây là giới hạn đã biết của cách dẫn xuất từ hội thoại.

**Phần native bắt buộc.** iOS phải báo cuộc gọi qua CallKit ngay khi nhận VoIP push, nếu không bị hệ điều hành chặn app. Android dùng ConnectionService hoặc full-screen intent. Đây là phần dễ bị App Store và Play Store từ chối nếu làm sai, nên cần dành thời gian riêng.

**Hạ tầng media**

- Pool node riêng cho media trên EKS, dùng `hostNetwork` và cổng User Datagram Protocol (UDP), TURN nhúng của LiveKit với TLS cổng 443 cho mạng chặn UDP.
- Redis cho định tuyến phòng giữa các node LiveKit; autoscale theo CPU và số phòng; triển khai theo vùng, phòng được gán vào node gần người tạo.
- Simulcast, dynacast và adaptive stream bật mặc định để tiết kiệm băng thông; audio dùng Opus với DTX và RED.

**Rủi ro cần PoC.** Hỗ trợ SFrame trên Safari và iOS Web, mức tương đương tính năng của SDK Flutter so với SDK gốc, và chi phí băng thông thực tế.

## 13. Mô hình dữ liệu

Ba kho với ba vai trò: PostgreSQL cho dữ liệu quan hệ ít ghi, DynamoDB cho đường nóng của tin nhắn, Valkey cho trạng thái tạm. Không kho nào lưu plaintext.

**PostgreSQL (metadata)**

| Bảng | Trường chính | Ghi chú |
| --- | --- | --- |
| `accounts` | `account_id` (UUIDv7), băm số điện thoại hoặc email, cài đặt, `created_at` | Khóa shard |
| `devices` | `device_id`, `account_id`, nền tảng, token push, khóa danh tính công khai, `revoked_at` | Một dòng mỗi thiết bị |
| `key_packages` | `device_id`, `kp_id`, blob, cờ last resort | Xóa khi bị tiêu thụ |
| `conversations` | `conv_id`, loại, `mls_group_id`, `created_at` |  |
| `members_by_conv` | `conv_id`, `account_id`, vai trò, `joined_at` | Truy vấn: ai trong hội thoại; có trạng thái đang rời (đặc tả giao thức, mục 6.4) |
| `convs_by_account` | `account_id`, `conv_id`, hoạt động gần nhất | Truy vấn: danh sách chat của tôi |
| `group_info` | `conv_id`, `epoch`, blob GroupInfo | Dùng cho External Commit |
| `calls` | `call_id`, `conv_id`, người gọi, thời gian, kết quả | Chỉ metadata |
| `media` | `media_id`, chủ sở hữu, kích thước, khóa object S3, `expires_at` |  |
| `backups` | `account_id`, khóa object, kích thước, `created_at` |  |
| device\_links | link\_id, account\_id, khóa tạm, thời điểm hết hạn | Liên kết thiết bị mới; TTL 5 phút |
| revocations | device\_id, account\_id, bản xác nhận thu hồi, revoked\_at | Chỉ thêm, không sửa; client lấy qua KeyService |

**DynamoDB (đường nóng)**

| Bảng | Khóa | Nội dung | Ghi chú |
| --- | --- | --- | --- |
| `conv_head` | PK `conv_id` | `head_seq`, `epoch` | Bộ đếm nguyên tử để cấp `seq` |
| `conv_log` | PK `conv_id#bucket`, SK `seq` | loại (app, commit, welcome), thiết bị gửi, ciphertext, TTL | `bucket` theo khoảng `seq` để tránh phân vùng nóng |
| `device_inbox` | PK `device_id`, SK `inbox_id` (Universally Unique Lexicographically Sortable Identifier, ULID) | `conv_id`, `seq`, loại, ciphertext trực tiếp cho Welcome, TTL | Xóa khi có ack |
| `dedup` | PK `conv_id#client_msg_id` | `seq` | TTL 24 giờ |

**Valkey.** Presence (`presence:<account_id>`, TTL 60 giây), bộ đếm rate limit, cache tư cách thành viên, nonce xác thực.

**Kế hoạch shard.** Mọi bảng Postgres đều có `account_id` hoặc `conv_id` làm cột đầu của khóa. Khi chạm trần, chuyển sang Citus hoặc CockroachDB mà không đổi schema. Truy cập kho đi qua `MetaStore` và `MailboxStore` để đổi nhà cung cấp được.

## 14. Bảo mật và chống lạm dụng

Phần lớn rủi ro nằm ở thiết bị và ở hành vi người dùng, không phải ở server, vì server không có plaintext. Vì vậy chống lạm dụng phải dựa vào hành vi và báo cáo, không dựa vào quét nội dung.

**Kênh truyền và xác thực**

- TLS 1.3 ở mọi nơi. Mobile có thể ghim khóa công khai kèm khóa dự phòng để xoay được.
- Đăng nhập bằng OTP và passkey, không lưu mật khẩu. Access token (PASETO) sống 15 phút; refresh token xoay vòng, gắn với `device_id`, và việc dùng lại token cũ sẽ thu hồi cả phiên.
- Khóa E2EE độc lập với đăng nhập: lộ tài khoản không đồng nghĩa lộ lịch sử.

**Trên thiết bị**

- DB cục bộ mã hóa bằng SQLCipher; khóa DB được bọc bởi Keychain, Keystore hoặc WebCrypto (khóa không xuất được).
- Khóa MLS không rời thiết bị. Tùy chọn khóa app bằng sinh trắc học và chặn chụp màn hình.

**Trên server**

- Mã hóa at-rest bằng Key Management Service (KMS) cho Aurora, DynamoDB, S3; bí mật nằm trong Secrets Manager; Identity and Access Management (IAM) tối thiểu theo dịch vụ.
- Không ghi log ciphertext hay payload; trace chỉ mang `message_id` và `conv_id`.

**Chống lạm dụng**

- Xác minh số điện thoại hoặc email, Turnstile ở API công khai.
- Rate limit token bucket theo tài khoản, thiết bị và IP cho gửi tin, tạo nhóm, thêm thành viên, xin OTP.
- Người lạ không thể kéo ai vào nhóm: lời mời cần được chấp nhận. Có chặn và báo cáo.
- Giai đoạn 2: message franking để báo cáo kèm tin đã giải mã có thể kiểm chứng mà không cần server đọc tin thường.

**Chuỗi cung ứng.** Khóa phiên bản phụ thuộc, tạo Software Bill of Materials (SBOM), quét lỗ hổng (`cargo audit`, `govulncheck`), ký bản phát hành.

**Kiểm toán.** Thuê audit mật mã và pentest độc lập trước khi ra mắt công khai; cân nhắc chương trình bug bounty sau đó.

**Pháp lý (cần luật sư xác nhận).** Việt Nam có Luật An ninh mạng, quy định bảo vệ dữ liệu cá nhân và quy định về kinh doanh sản phẩm, dịch vụ mật mã dân sự; cần xác minh ứng dụng E2EE có thuộc diện giấy phép hay yêu cầu lưu trữ dữ liệu trong nước hay không. Với App Store và Google Play, cần khai báo việc sử dụng mã hóa.

## 15. Scale, dung lượng và vận hành

Không có điểm nghẽn cố định: gateway mở rộng bằng cách thêm node, hộp thư mở rộng bằng DynamoDB, metadata mở rộng bằng shard theo `account_id`. Bảng dưới là ước lượng thô để định cỡ, cần thay bằng số đo từ load test.

| Kết nối đồng thời | Node gateway | Tin/giây đỉnh | Ghi DynamoDB/giây đỉnh | Việc cần làm ở mức này |
| --- | --- | --- | --- | --- |
| 1 triệu | khoảng 10 | khoảng 5.000 | khoảng 27.000 | Một vùng, Aurora một writer cộng replica |
| 10 triệu | khoảng 100 | khoảng 50.000 | khoảng 275.000 | Shard Postgres (Citus), tăng hạn mức DynamoDB, NATS cụm lớn |
| 100 triệu | khoảng 1.000 | khoảng 500.000 | khoảng 2,75 triệu | Nhiều vùng, tài khoản gán vào vùng nhà, chi phí ghi cần tối ưu lại |

Giả định: 100.000 kết nối mỗi node (4 vCPU, 16 GB), 0,005 tin/giây mỗi kết nối đồng thời, và khoảng 5,5 lần ghi mỗi tin (1 `conv_log`, 1 `conv_head`, 1 `dedup`, khoảng 2,5 con trỏ hộp thư). Ở quy mô lớn, gộp ghi và bỏ bớt `dedup` bằng khóa trên `conv_log` là các tối ưu đầu tiên.

**Gateway**

- Không giữ trạng thái nghiệp vụ, chỉ giữ kết nối và đăng ký NATS. Tinh chỉnh `ulimit`, bộ đệm TCP, kích thước buffer mỗi kết nối.
- Triển khai bằng rolling update, drain từng node, báo client kết nối lại kèm jitter để không gây thundering herd.
- Giới hạn tốc độ kết nối mới mỗi giây ở mỗi node.

**Nhiều vùng.** Mỗi tài khoản có vùng nhà; hộp thư và metadata nằm ở vùng nhà. Tin gửi sang vùng khác đi qua NATS giữa các vùng. Bảng tra cứu tài khoản tới vùng là bảng nhỏ, nhân bản toàn cầu.

**Quan sát**

- Chỉ số chính: độ trễ gửi-nhận đầu cuối (client đo từ lúc gửi tới ack), tỷ lệ giao thành công, số kết nối, độ trễ hộp thư, tỷ lệ lỗi push, Round-Trip Time (RTT) và mất gói của cuộc gọi.
- Service Level Objective (SLO) và cảnh báo theo tốc độ đốt ngân sách lỗi; trace theo `message_id` bằng OpenTelemetry.
- Phát hành canary và cờ tính năng. Load test bằng client Go giả lập. Thử chaos định kỳ (tắt node gateway, mất kết nối NATS).

**Độ bền và khôi phục.** Aurora bật backup liên tục, DynamoDB bật point-in-time recovery. Mục tiêu Recovery Point Objective (RPO) dưới 5 phút cho metadata; chốt Recovery Time Objective (RTO) sau khi diễn tập khôi phục lần đầu.

**Chi phí.** Đặt cảnh báo ngân sách theo từng dịch vụ và theo chi phí mỗi phút gọi video, vì video và media là hai khoản tăng nhanh nhất.

## 16. Lộ trình, PoC và rủi ro

Khoảng 12 tháng toàn thời gian cho một người, chia năm giai đoạn. PoC chạy trước để loại sớm các rủi ro kỹ thuật lớn nhất, và gọi video chỉ bắt đầu sau khi chat 1-1 và nhóm đã ổn định.

&#91;embedded content: lộ trình · 5 giai đoạn, 5 cổng nghiệm thu\]

Mỗi giai đoạn kết thúc bằng một cổng nghiệm thu; chưa đạt thì chưa sang giai đoạn sau. Thời lượng là ước lượng thô và sẽ lệch tùy kinh nghiệm của bạn với Rust, Flutter và lập trình mobile native.

**PoC cần làm trong giai đoạn PoC**

| PoC | Câu hỏi cần trả lời | Tiêu chí đạt (mục tiêu, cần xác nhận) |
| --- | --- | --- |
| MLS đa nền tảng | OpenMLS chạy ổn trên Android, WASM và desktop không? | Tạo nhóm, thêm bớt thành viên, gửi nhận giữa ba nền tảng; nhóm 1.000 thiết bị xử lý Commit dưới 1 giây trên điện thoại tầm trung |
| Gọi video E2EE | LiveKit với SFrame chạy được trên Flutter Android và trình duyệt web (Chromium) không? | Cuộc gọi 4 người có E2EE trên mọi nền tảng; đổi khóa khi có người vào hoặc ra mà không mất tiếng |
| Tải gateway | Một node Go giữ được bao nhiêu kết nối? | 10.000 kết nối ổn định trên một máy cục bộ, đo CPU và bộ nhớ mỗi kết nối để ngoại suy ra 100.000 trên 4 vCPU và 16 GB; p95 gửi-nhận dưới 200 ms ở 1.000 tin/giây; kiểm tra thật 100.000 kết nối (có phí) để sau |
| Flutter Web + WASM | SQLite trên OPFS, Web Worker, COOP/COEP chạy ổn không? | Lưu và tìm kiếm 1 triệu tin cục bộ dưới 200 ms |

Kết quả PoC đến 06/11/2026: MLS đa nền tảng (Windows, WASM trên Chrome, Android emulator), gọi video E2EE trên Chrome với xoay khóa, tải gateway ở 10.000 kết nối, SQLite trên OPFS và cầu nối Dart và JavaScript trong Flutter Web đều đạt; số đo chi tiết ở mục 8 của đặc tả giao thức. Chưa kiểm: máy ARM thật, video trên Flutter Android và Safari.

**Rủi ro lớn nhất**

| Rủi ro | Hệ quả | Giảm thiểu |
| --- | --- | --- |
| Một người là điểm lỗi duy nhất | Sự cố kéo dài, kiệt sức | Dịch vụ managed, runbook, cảnh báo, ranh giới giờ trực rõ ràng |
| Lỗi mật mã | Mất niềm tin, khó sửa sau khi ra mắt | Không tự viết primitive, dùng test vector, audit độc lập |
| Chi phí video tăng nhanh | Lỗ khi mở rộng | Giới hạn cuộc gọi, theo dõi chi phí mỗi phút, bắt đầu bằng LiveKit Cloud |
| Spam và lạm dụng | Bị gỡ app, rủi ro pháp lý | Xác minh, rate limit, báo cáo, message franking |
| Pháp lý về mật mã và dữ liệu | Phải xin giấy phép hoặc đổi kiến trúc | Tư vấn luật sớm, trước giai đoạn beta mở |
| Phạm vi phình ra | Trễ lộ trình | Khóa phạm vi MVP, desktop và gọi video chỉ bắt đầu sau cổng tương ứng |

## 17. Phụ lục: bảng quyết định kiến trúc

Mỗi quyết định kèm phương án đã loại và điều kiện để xem lại.

| # | Quyết định | Lý do | Đã loại | Xem lại khi |
| --- | --- | --- | --- | --- |
| 1 | MLS cho mọi hội thoại | Một giao thức cho 1-1, nhóm, đa thiết bị; lưu một bản ciphertext | Signal Protocol + Sender Keys | PoC MLS không đạt hoặc thư viện thiếu ổn định |
| 2 | Flutter cho cả bốn nền tảng | Một codebase UI cho một người | React Native + web riêng; native từng nền tảng | Flutter Web hoặc E2EE gọi video trên Safari không đạt |
| 3 | Go cho backend | Đơn giản, hệ sinh thái NATS và LiveKit | Elixir, Rust | Không đạt 100.000 kết nối mỗi node |
| 4 | DynamoDB cho hộp thư | Scale tự động, TTL sẵn | ScyllaDB, Cassandra, Postgres | Chi phí ghi vượt ngưỡng hoặc cần đa đám mây |
| 5 | NATS JetStream | Định tuyến theo subject, vận hành nhẹ | Kafka, Redis pub/sub | Độ bền hoặc số subscription vượt khả năng |
| 6 | LiveKit | SFU hoàn chỉnh, có E2EE | Tự viết trên mediasoup hoặc Janus; Twilio, Agora | Giá hoặc E2EE không đạt |
| 7 | Ciphertext có TTL 30 ngày | Chi phí và quyền riêng tư | Lưu vĩnh viễn trên server | Sản phẩm cần lịch sử phía server |
| 8 | Tìm kiếm cục bộ | Tương thích E2EE | Chỉ mục phía server | Cần tìm kiếm xuyên thiết bị mà không tải lịch sử |
| 9 | Amazon S3 cho media và sao lưu (thay R2 từ 1.4.0, ADR 0014) | Cùng nhà cung cấp, IAM role, lifecycle, SSE-KMS | Cloudflare R2 | Chi phí egress media vượt ngân sách mà CloudFront không giảm đủ |
| 10 | Postgres, shard sau bằng Citus | Đơn giản trước, khóa shard đặt sẵn | CockroachDB ngay từ đầu | Node ghi chạm trần |
| 11 | Kiểm tra epoch ở server | Server từ chối tin mang epoch cũ nên client không giữ khóa của các epoch trước; Commit được xếp thứ tự bằng ghi có điều kiện | Client tự giữ khóa của nhiều epoch | Tỉ lệ EPOCH\_MISMATCH làm chậm việc gửi tin đáng kể |
| 12 | External Commit cho thiết bị mới | Thiết bị mới tự vào từng nhóm, thiết bị cũ không cần online; PoC MLS xác nhận cách này chạy trên Windows, WASM và Android | Thiết bị cũ lần lượt Add thiết bị mới vào từng nhóm | Server không kiểm tra được credential của External Commit hoặc thư viện thiếu ổn định |

## 18. Phạm vi và phiên bản

**Phiên bản hiện tại 1.4.0 (đổi R2 thành S3, ADR 0014); Phạm vi đã chốt từ 1.0.0 ngày 03/11/2026; bản 1.1.0 đóng phần thiết kế bổ sung cho phiên bản đầu; bản 1.2.0 thu hẹp bản đầu xuống ba nền tảng; bản 1.3.0 đưa vào các điều chỉnh sau khi PoC đạt và đặc tả giao thức chốt 1.0.0, không mở rộng thêm.** Tài liệu này là bản thiết kế kiến trúc nền; phạm vi không mở rộng thêm, và mọi thay đổi sau ngày chốt đi qua quy trình ở cuối mục.

| Phiên bản | Ngày | Nội dung |
| --- | --- | --- |
| 1.3.0 | 06/11/2026 | Đưa vào các điều chỉnh sau PoC (đặc tả giao thức 1.0.0): mục 7 trỏ sang đặc tả cho định nghĩa Protobuf; mục 8 kiểm tra epoch ở server, Commit và Welcome qua SubmitCommit, con trỏ hộp thư qua hàng đợi bền; mục 9 server kiểm tra External Commit và giữ bản sao vai trò; mục 10 thiết bị mới tự vào nhóm bằng External Commit; mục 12 quy tắc chuyển khóa cuộc gọi; mục 13 thêm device\_links, revocations và trạng thái đang rời; mục 17 thêm quyết định 11 và 12. Không đổi phạm vi |
| 1.2.0 | 04/11/2026 | Thu hẹp bản đầu xuống ba nền tảng (Android, Web, desktop); iOS để sau, thiết kế iOS giữ nguyên nhưng chưa phát hành. Bỏ PoC giải mã push trên iOS; PoC tải gateway chạy 10.000 kết nối cục bộ rồi ngoại suy, kiểm tra thật 100.000 kết nối (có phí) để sau. Không đổi quyết định ở mục 17 |
| 1.1.0 | 04/11/2026 | Thiết kế bổ sung từ backlog: đăng nhập bằng passkey; hồ sơ do máy chủ lưu dạng thường (ảnh đại diện là tệp công khai); chặn người dùng cho cuộc 1-1; khung WebSocket báo cuộc gọi đến khi ứng dụng đang mở; tìm người bằng số điện thoại hoặc email nhập chính xác; khôi phục tài khoản bằng OTP và bản sao lưu. Thêm ProfileService và BlockService. Chi tiết nằm trong đặc tả giao thức 0.2.0 và tài liệu màn hình 0.2.0 |
| 1.0.4 | 04/11/2026 | Bỏ phần giải thích trong ngoặc; từ viết tắt chỉ còn được viết đầy đủ kèm tên ngắn ở lần xuất hiện đầu tiên; viết lại mục xác thực danh tính (mục 9) cho khớp việc ẩn E2EE; không đổi thiết kế |
| 1.0.3 | 04/11/2026 | Bỏ mục 19 (thuật ngữ và từ viết tắt); mỗi thuật ngữ và từ viết tắt được giải thích ngay tại lần xuất hiện đầu tiên trong nội dung, dạng "Thuật ngữ (tên đầy đủ: giải thích)"; không đổi thiết kế |
| 1.0.2 | 03/11/2026 | Bỏ mốc theo tuần ở mục 16 và sơ đồ lộ trình; sửa mục 7: đã xem và typing đi trong tin điều khiển mã hóa, không có trường riêng trong khung WebSocket |
| 1.0.1 | 03/11/2026 | Thêm mục 19 (thuật ngữ và từ viết tắt); không đổi thiết kế |
| 1.0.0 | 03/11/2026 | Chốt phạm vi: chat 1-1 và nhóm có E2EE (MLS), đa thiết bị, media mã hóa, gọi thoại và video, bốn nền tảng, stack, mô hình dữ liệu, lộ trình, rủi ro |

**Trong phạm vi 1.0.0**

- Mục 1-17 như đã viết: yêu cầu, kiến trúc, stack, client, giao thức, luồng tin, E2EE, nhóm và đa thiết bị, media, gọi video, dữ liệu, bảo mật, scale, lộ trình, quyết định kiến trúc.

**Ngoài phạm vi 1.0.0 (giữ nguyên như mục 2)**

- Bot và API mở, kênh phát sóng hàng trăm nghìn người, stories, thanh toán, SSO doanh nghiệp, tìm kiếm phía server.

**Backlog cho 1.1 (đã biết, chưa thiết kế, không chặn bản 1.0.0)**

- Đồng bộ danh bạ và tìm theo tên: bản 1 chỉ cho nhập chính xác số điện thoại hoặc email; cách đối chiếu danh bạ mà không lộ danh bạ còn để sau.
- Vòng đời tài khoản: đổi số điện thoại, xóa tài khoản và dữ liệu; khôi phục tài khoản đã thiết kế ở 1.1.0, riêng việc quay lại nhóm cũ khi không có bản sao lưu còn mở.
- Chiến lược kiểm thử: test vector mật mã, load test, kiểm thử đa nền tảng.
- Mô hình chi phí chi tiết theo quy mô, đặc biệt media và video.
- Công cụ quản trị: xử lý báo cáo lạm dụng, khóa tài khoản.
- Kết quả bốn PoC ở mục 16; nếu một PoC không đạt thì quyết định liên quan ở mục 17 được xem lại và phát hành 1.0.x hoặc 2.0.0.

**Quy tắc thay đổi.** Sửa lỗi chính tả hoặc làm rõ không đổi nghĩa tăng số cuối (1.0.1). Bổ sung thiết kế trong backlog tăng số giữa (1.1.0). Đổi một quyết định ở mục 17 hoặc mở rộng phạm vi tăng số đầu (2.0.0), kèm cập nhật bảng phiên bản này.
