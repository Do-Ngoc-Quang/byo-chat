# Đặc tả giao thức và luồng MLS cho hệ thống Chat

Nov 3, 2026 · @Quang

**Phiên bản:** 1.1.0

## 1. Phạm vi và phiên bản

Tài liệu này đặc tả giao thức giữa client và server, cùng các luồng MLS chi tiết, cho hệ thống trong tài liệu "Thiết kế hệ thống Chat đa nền tảng: E2EE và gọi video" (bản 1.3.0, gọi là *tài liệu chính*). Phiên bản hiện tại là **1.1.0**: các PoC bắt buộc đã đạt (mục 8), đủ để bắt đầu phát triển; các điểm mở còn lại ở mục 9 xử lý trong giai đoạn phát triển, không chặn.

**Trong phạm vi:** giao thức WebSocket, định nghĩa Protobuf cho WebSocket và Connect RPC, mã lỗi, các luồng MLS, máy trạng thái của tin nhắn và kết nối, ánh xạ sang PoC.

**Ngoài phạm vi:** giao diện người dùng, hạ tầng và chi phí, và chi tiết bên trong thuật toán MLS (theo RFC 9420 và thư viện OpenMLS).

**Điều chỉnh so với tài liệu chính.** Khi viết đặc tả có bốn điểm cần chốt rõ hơn; chi tiết ở mục 9.

- Commit và Welcome của MLS gửi qua RPC `SubmitCommit` (nguyên tử), không qua `SendMessage` của WebSocket.
- Server từ chối `SendMessage` mang epoch cũ, nên client không cần giữ khóa của các epoch trước.
- Thiết bị mới tự vào từng nhóm bằng External Commit, thay vì chờ thiết bị cũ thêm vào.
- Đã xem và typing là tin điều khiển mã hóa, không có trường riêng trong khung WebSocket (đã sửa ở mục 7 của tài liệu chính, bản 1.0.2).

Thuật ngữ và từ viết tắt xem mục 19 của tài liệu chính.

## 2. Quy ước chung

Các quy ước này áp dụng cho mọi thông điệp, ở cả WebSocket lẫn Connect RPC. Giá trị số là giá trị khởi điểm, sẽ chỉnh sau khi có số đo từ PoC.

| Chủ đề | Quy ước |
| --- | --- |
| Định danh | `account_id`, `device_id`, `conv_id`, `client_msg_id`, `message_id`, `call_id`, `media_id` là UUIDv7, 16 byte nhị phân trong Protobuf, chuỗi chữ thường có gạch ngang trong URL và log. `inbox_id` là ULID 16 byte |
| Nhóm MLS | `group_id` là 32 byte ngẫu nhiên do client sinh, ánh xạ một-một với `conv_id` ở server |
| Thời gian | Số nguyên 64 bit, mili giây từ epoch Unix (UTC), tên trường có hậu tố `_ms`. `server_ts_ms` là chuẩn; client không dùng đồng hồ máy để sắp xếp tin |
| Thứ tự | `seq` (uint64, bắt đầu từ 1, tăng đúng 1 trong mỗi hội thoại) là thứ tự duy nhất của hội thoại |
| Ciphertext | `bytes`, giữ nguyên định dạng `MLSMessage` của RFC 9420, không nén, không sửa |
| JSON | Connect RPC ở chế độ JSON mã hóa số 64 bit thành chuỗi theo quy tắc proto3 JSON |
| Xác thực | RPC dùng header `Authorization: Bearer <access_token>`. WebSocket gửi token trong `Hello`, không đặt trong URL để tránh lọt vào log |
| Idempotency | Mọi RPC ghi nhận header `Idempotency-Key` (UUIDv7); server lưu kết quả 24 giờ và trả lại đúng kết quả đó khi gặp lại khóa |
| Phiên bản | `proto_version` là số nguyên, hiện là 1. Server hỗ trợ hai phiên bản gần nhất. Chỉ thêm trường mới; không đổi số hiệu hay kiểu; trường bỏ đi phải `reserved` |
| Đặt tên | Package `chat.v1`; message PascalCase, trường snake\_case, enum UPPER\_SNAKE có tiền tố tên enum |

**Giới hạn khởi điểm**

| Mục | Giới hạn |
| --- | --- |
| Khung WebSocket | 256 KiB (`max_frame_bytes` do server báo trong `Welcome`) |
| Ciphertext của một tin | 64 KiB; nội dung lớn hơn đi qua media |
| Commit | 128 KiB (chỉnh sau khi đo ở giai đoạn 4) |
| GroupInfo | 128 KiB (chỉnh sau khi đo ở giai đoạn 4) |
| Tổng Welcome mỗi Commit | 3 MiB (chưa đo kích thước Welcome; chỉnh ở giai đoạn 4) |
| KeyPackage | 4 KiB mỗi cái, tối đa 200 cái mỗi lần tải lên |
| Thiết bị trong một nhóm | 1.000 (PoC MLS sẽ xác nhận) |
| Tốc độ gửi tin | 10 tin/giây mỗi thiết bị, burst 30 |
| Đăng ký presence | 500 tài khoản mỗi kết nối |

## 3. Giao thức WebSocket

Điểm vào là `wss://ws.<miền>/v1/connect`, khung nhị phân Protobuf, subprotocol `chat.v1`. Mỗi thiết bị chỉ có một kết nối tại một thời điểm.

**Bắt tay**

1. Client mở WSS (TLS 1.3) và yêu cầu subprotocol `chat.v1`.
2. Trong 5 giây client phải gửi `Hello` là khung đầu tiên, nếu không server đóng kết nối mã 4001.
3. Server xác thực token, kiểm tra thiết bị chưa bị thu hồi, đăng ký subject NATS `dev.<device_id>`, và đóng kết nối cũ của cùng thiết bị (mã 4010).
4. Server trả `Welcome`, rồi gửi lần lượt các `Deliver` còn tồn đọng, theo `inbox_id` tăng dần, bắt đầu sau `inbox_cursor` mà client đã báo.
5. Hết tồn đọng, server gửi `SyncDone`. Client chuyển sang trạng thái online và có thể gửi tin ngay từ sau `Welcome`.

**Mã đóng kết nối**

| Mã | Ý nghĩa | Client làm gì |
| --- | --- | --- |
| 4000 | Lỗi giao thức (khung sai định dạng) | Ghi log, kết nối lại với backoff |
| 4001 | Chưa xác thực hoặc quá hạn `Hello` | Kết nối lại |
| 4002 | Token hết hạn | Làm mới token rồi kết nối lại |
| 4003 | Thiết bị đã bị thu hồi | Xóa dữ liệu cục bộ, về màn hình đăng nhập |
| 4004 | Phiên bản giao thức không hỗ trợ | Yêu cầu cập nhật app |
| 4008 | Vượt giới hạn tốc độ | Chờ `retry_after_ms` |
| 4009 | Server đang drain | Kết nối lại sau 0-30 giây ngẫu nhiên |
| 4010 | Bị thay bởi kết nối mới của cùng thiết bị | Không kết nối lại tự động |

**Heartbeat.** Client gửi `Ping` mỗi `heartbeat_ms` (khởi điểm 25 giây); server trả `Pong`. Không nhận khung nào trong hai chu kỳ thì hai bên đóng kết nối. Mọi khung nhận được đều tính là tín hiệu sống.

**Gửi tin.** Client gửi `SendMessage`, server trả `SendResult` hoặc `Error` cùng `req_id`. Nếu mất kết nối trước khi có phản hồi, client gửi lại với đúng `client_msg_id` cũ; server khử trùng và trả kết quả ban đầu với `duplicate = true`.

**Nhận tin và Ack**

- Client chỉ gửi `Ack` sau khi đã giải mã và ghi bền vào DB cục bộ.
- Server giới hạn số `Deliver` chưa ack ở mức `window` (khởi điểm 256) để tránh tràn bộ nhớ client.
- Tin chưa ack sẽ được gửi lại khi kết nối lại (at-least-once). Client khử trùng theo `(conv_id, seq)`.
- Client áp dụng tin theo `seq` tăng dần trong từng hội thoại. Gặp khoảng trống thì giữ các tin đến sau tối đa 5 giây, hết hạn thì gọi `ConversationService.FetchLog(conv_id, after_seq)` để lấy phần thiếu.

**Kết nối lại.** Backoff tăng gấp đôi từ 1 giây tới tối đa 60 giây, cộng jitter ±50%. Khi đổi mạng (Wi-Fi sang 4G) client chủ động đóng và mở lại. Sau 3 lần thất bại liên tiếp, client chuyển sang HTTP streaming `POST /v1/stream` dùng cùng khung (kèm tiền tố độ dài) cho tới khi WebSocket mở lại được.

## 4. Định nghĩa Protobuf

Bốn file cùng package `chat.v1`, quản lý bằng buf: `common.proto` và `ws.proto` (khung WebSocket) ở mục 4.1, `services.proto` (Connect RPC) ở mục 4.2, `payload.proto` (nội dung bên trong MLS) ở mục 7.3. `CallKind` nằm trong `common.proto` vì cả `ws.proto` và `services.proto` dùng; số trường không đổi. Các trường `bytes` mang định danh là 16 byte nhị phân theo mục 2.

### 4.1 `common.proto` và `ws.proto`

```protobuf
syntax = "proto3";
package chat.v1;

enum ConvKind { CONV_KIND_UNSPECIFIED = 0; CONV_KIND_DIRECT = 1; CONV_KIND_GROUP = 2; }
enum Role { ROLE_UNSPECIFIED = 0; ROLE_MEMBER = 1; ROLE_ADMIN = 2; ROLE_OWNER = 3; }
enum Platform {
  PLATFORM_UNSPECIFIED = 0; PLATFORM_IOS = 1; PLATFORM_ANDROID = 2; PLATFORM_WEB = 3;
  PLATFORM_MACOS = 4; PLATFORM_WINDOWS = 5; PLATFORM_LINUX = 6;
}

// Loại mục trong conv_log. Tin điều khiển (đã xem, typing, reaction...) cũng là APPLICATION:
// server không phân biệt được chúng với tin thường.
enum EntryKind {
  ENTRY_KIND_UNSPECIFIED = 0;
  ENTRY_KIND_APPLICATION = 1;
  ENTRY_KIND_COMMIT = 2;
  ENTRY_KIND_WELCOME = 3;   // chỉ nằm trong hộp thư của thiết bị nhận
  ENTRY_KIND_PROPOSAL = 4;
}

enum CallKind { CALL_KIND_UNSPECIFIED = 0; CALL_KIND_AUDIO = 1; CALL_KIND_VIDEO = 2; }

enum ErrorCode {
  ERROR_CODE_UNSPECIFIED = 0;
  ERROR_CODE_UNAUTHENTICATED = 1;
  ERROR_CODE_PERMISSION_DENIED = 2;
  ERROR_CODE_NOT_FOUND = 3;
  ERROR_CODE_INVALID_ARGUMENT = 4;
  ERROR_CODE_RATE_LIMITED = 5;
  ERROR_CODE_EPOCH_MISMATCH = 6;     // kèm current_epoch
  ERROR_CODE_ALREADY_EXISTS = 7;
  ERROR_CODE_DEVICE_REVOKED = 8;
  ERROR_CODE_VERSION_UNSUPPORTED = 9;
  ERROR_CODE_PAYLOAD_TOO_LARGE = 10;
  ERROR_CODE_UNAVAILABLE = 11;
}

message Error {
  ErrorCode code = 1;
  string message = 2;          // cho log, không hiển thị cho người dùng
  uint32 retry_after_ms = 3;
  uint64 current_epoch = 4;    // chỉ có khi EPOCH_MISMATCH
}

message Member { bytes account_id = 1; Role role = 2; }

// ---------------- ws.proto ----------------
message ClientFrame {
  reserved 13, 14;  // đã xem và typing đi trong SendMessage
  uint64 req_id = 1;
  oneof body {
    Hello hello = 10;
    SendMessage send = 11;
    Ack ack = 12;
    PresenceSub presence_sub = 15;
    Ping ping = 16;
  }
}

message ServerFrame {
  reserved 14;
  uint64 req_id = 1;           // 0 nếu là sự kiện chủ động từ server
  oneof body {
    Welcome welcome = 10;
    SendResult send_result = 11;
    Deliver deliver = 12;
    DeliveredReceipt receipt = 13;
    PresenceEvent presence = 15;
    Error error = 16;
    Pong pong = 17;
    SyncDone sync_done = 18;
    IncomingCall incoming_call = 19;   // cuộc gọi đến khi app đang mở (6.10)
  }
}

message Hello {
  uint32 proto_version = 1;
  bytes device_id = 2;
  string access_token = 3;
  bytes inbox_cursor = 4;      // inbox_id cuối đã ack; rỗng = từ đầu
  Platform platform = 5;
  string app_version = 6;
}

message Welcome {
  uint32 negotiated_version = 1;
  bytes session_id = 2;
  uint32 heartbeat_ms = 3;     // khởi điểm 25000
  uint32 window = 4;           // số Deliver chưa ack tối đa
  uint32 max_frame_bytes = 5;
  uint64 server_time_ms = 6;
}

// Chỉ dành cho tin APPLICATION. Commit, Welcome, Proposal đi qua ConversationService.
message SendMessage {
  bytes conv_id = 1;
  bytes client_msg_id = 2;
  uint64 mls_epoch = 3;        // phải bằng epoch hiện tại của hội thoại
  bytes ciphertext = 4;
  bool ephemeral = 5;          // true: không ghi hộp thư (typing)
}

message SendResult {
  bytes client_msg_id = 1;
  bytes message_id = 2;
  uint64 seq = 3;
  uint64 server_ts_ms = 4;
  bool duplicate = 5;
}

message Deliver {
  bytes inbox_id = 1;          // rỗng nếu ephemeral
  bytes conv_id = 2;
  uint64 seq = 3;              // 0 nếu ephemeral
  EntryKind kind = 4;
  bytes sender_device_id = 5;
  uint64 mls_epoch = 6;
  bytes ciphertext = 7;
  uint64 server_ts_ms = 8;
}

message Ack { repeated bytes inbox_ids = 1; }
message SyncDone { bytes last_inbox_id = 1; }

// Chỉ gửi cho hội thoại 1-1 và nhóm tối đa 50 tài khoản.
message DeliveredReceipt { bytes conv_id = 1; uint64 seq = 2; bytes device_id = 3; }

message PresenceSub { repeated bytes account_ids = 1; bool unsubscribe = 2; }
message PresenceEvent { bytes account_id = 1; bool online = 2; uint64 last_seen_ms = 3; }
message Ping { uint64 nonce = 1; }
message Pong { uint64 nonce = 1; }
message IncomingCall { bytes call_id = 1; bytes conv_id = 2; CallKind kind = 3; bytes caller_account_id = 4; uint64 started_ms = 5; }
```

### 4.2 `services.proto`

```protobuf
syntax = "proto3";
package chat.v1;

// ---------- AuthService ----------
service AuthService {
  rpc RequestOtp(RequestOtpRequest) returns (RequestOtpResponse);
  rpc VerifyOtp(VerifyOtpRequest) returns (VerifyOtpResponse);
  rpc RefreshToken(RefreshTokenRequest) returns (TokenPair);
  rpc BeginPasskeyRegistration(BeginPasskeyRegistrationRequest) returns (PasskeyChallenge); // cần access token
  rpc FinishPasskeyRegistration(FinishPasskeyRegistrationRequest) returns (FinishPasskeyRegistrationResponse);
  rpc BeginPasskeyLogin(BeginPasskeyLoginRequest) returns (PasskeyChallenge);               // chưa đăng nhập
  rpc FinishPasskeyLogin(FinishPasskeyLoginRequest) returns (VerifyOtpResponse);            // trả session_ticket như VerifyOtp
}
enum OtpChannel { OTP_CHANNEL_UNSPECIFIED = 0; OTP_CHANNEL_SMS = 1; OTP_CHANNEL_EMAIL = 2; }
message RequestOtpRequest { OtpChannel channel = 1; string destination = 2; string captcha_token = 3; }
message RequestOtpResponse { bytes challenge_id = 1; uint32 retry_after_ms = 2; }
message VerifyOtpRequest { bytes challenge_id = 1; string code = 2; }
message VerifyOtpResponse {
  bytes account_id = 1;
  bool is_new_account = 2;
  bytes session_ticket = 3;    // dùng một lần, sống 10 phút, đổi lấy thiết bị ở RegisterDevice
}
message RefreshTokenRequest { bytes device_id = 1; string refresh_token = 2; }
message TokenPair { string access_token = 1; string refresh_token = 2; uint64 access_expires_ms = 3; }
message PasskeyChallenge { bytes challenge_id = 1; bytes options = 2; uint64 expires_ms = 3; } // options: JSON WebAuthn
message BeginPasskeyRegistrationRequest {}
message FinishPasskeyRegistrationRequest { bytes challenge_id = 1; bytes attestation = 2; string name = 3; }
message FinishPasskeyRegistrationResponse {}
message BeginPasskeyLoginRequest {}
message FinishPasskeyLoginRequest { bytes challenge_id = 1; bytes assertion = 2; }

// ---------- DeviceService ----------
service DeviceService {
  rpc RegisterDevice(RegisterDeviceRequest) returns (RegisterDeviceResponse);
  rpc StartLink(StartLinkRequest) returns (StartLinkResponse);          // thiết bị mới, chưa đăng nhập
  rpc ApproveLink(ApproveLinkRequest) returns (ApproveLinkResponse);    // thiết bị cũ đã tin cậy
  rpc CompleteLink(CompleteLinkRequest) returns (CompleteLinkResponse); // thiết bị mới, chờ tối đa 30 giây
  rpc ListDevices(ListDevicesRequest) returns (ListDevicesResponse);
  rpc RevokeDevice(RevokeDeviceRequest) returns (RevokeDeviceResponse);
}
message RegisterDeviceRequest {
  bytes session_ticket = 1;
  bytes device_id = 2;                  // client sinh (UUIDv7)
  Platform platform = 3;
  string device_name = 4;
  bytes device_public_key = 5;          // khóa ký Ed25519 của thiết bị
  bytes credential = 6;                 // đã được khóa danh tính tài khoản ký
  bytes account_identity_public_key = 7; // chỉ gửi ở thiết bị đầu tiên của tài khoản
  repeated bytes key_packages = 8;
  bytes last_resort_key_package = 9;
  bool reset_identity = 10;             // khôi phục không có bản sao lưu: đặt khóa danh tính tài khoản mới (xem 6.14)
}
message RegisterDeviceResponse { TokenPair tokens = 1; }

message StartLinkRequest { Platform platform = 1; string device_name = 2; bytes device_public_key = 3; bytes ephemeral_public_key = 4; }
message StartLinkResponse { bytes link_id = 1; string short_code = 2; uint64 expires_ms = 3; }
message ApproveLinkRequest {
  bytes link_id = 1;
  bytes credential = 2;                 // thiết bị cũ ký credential cho thiết bị mới
  bytes sealed_bundle = 3;              // khóa danh tính tài khoản, mã hóa bằng ECDH với ephemeral_public_key
}
message ApproveLinkResponse {}
message CompleteLinkRequest { bytes link_id = 1; }
message CompleteLinkResponse { bytes credential = 1; bytes sealed_bundle = 2; bytes session_ticket = 3; }

message DeviceInfo { bytes device_id = 1; Platform platform = 2; string device_name = 3; uint64 created_ms = 4; uint64 last_seen_ms = 5; bool revoked = 6; }
message ListDevicesRequest {}
message ListDevicesResponse { repeated DeviceInfo devices = 1; }
message RevokeDeviceRequest { bytes device_id = 1; bytes revocation_statement = 2; } // ký bằng khóa danh tính tài khoản
message RevokeDeviceResponse {}

// ---------- KeyService ----------
service KeyService {
  rpc UploadKeyPackages(UploadKeyPackagesRequest) returns (KeyPackageCount);
  rpc CountKeyPackages(CountKeyPackagesRequest) returns (KeyPackageCount);
  rpc FetchKeyPackages(FetchKeyPackagesRequest) returns (FetchKeyPackagesResponse);
}
message UploadKeyPackagesRequest { repeated bytes key_packages = 1; }
message CountKeyPackagesRequest {}
message KeyPackageCount { uint32 remaining = 1; }
message FetchKeyPackagesRequest { repeated bytes account_ids = 1; }
message DeviceKeyPackage {
  bytes device_id = 1;
  bytes key_package = 2;
  bool last_resort = 3;                 // true: gói dùng lại, kém an toàn hơn gói một lần
  bytes credential = 4;
}
message AccountKeys {
  bytes account_id = 1;
  bytes account_identity_public_key = 2;
  repeated DeviceKeyPackage devices = 3; // mỗi thiết bị còn hiệu lực một gói
  repeated bytes revocation_statements = 4;
}
message FetchKeyPackagesResponse { repeated AccountKeys accounts = 1; }

// ---------- ConversationService ----------
service ConversationService {
  rpc CreateConversation(CreateConversationRequest) returns (CreateConversationResponse);
  rpc SubmitCommit(SubmitCommitRequest) returns (SubmitCommitResponse);
  rpc SubmitProposal(SubmitProposalRequest) returns (SubmitProposalResponse);
  rpc FetchLog(FetchLogRequest) returns (FetchLogResponse);
  rpc GetGroupInfo(GetGroupInfoRequest) returns (GetGroupInfoResponse);
  rpc ListConversations(ListConversationsRequest) returns (ListConversationsResponse);
}
message WelcomeEnvelope { bytes recipient_device_id = 1; bytes welcome = 2; }

message CreateConversationRequest {
  ConvKind kind = 1;
  bytes group_id = 2;
  repeated Member members = 3;          // gồm cả người tạo; server cần để định tuyến
  bytes commit = 4;                     // Commit đầu tiên (epoch 0 sang 1)
  repeated WelcomeEnvelope welcomes = 5;
  bytes group_info = 6;
}
message CreateConversationResponse {
  bytes conv_id = 1;
  bool existed = 2;                     // 1-1 đã tồn tại: không ghi gì, client bỏ nhóm vừa tạo
  uint64 seq = 3;
  uint64 epoch = 4;
}

message SubmitCommitRequest {
  bytes conv_id = 1;
  uint64 expected_epoch = 2;            // epoch mà Commit được dựng trên đó
  bytes commit = 3;
  repeated WelcomeEnvelope welcomes = 4;
  bytes group_info = 5;                 // GroupInfo của epoch mới
  repeated Member added = 6;
  repeated bytes removed_account_ids = 7;
  repeated bytes removed_device_ids = 8;
  repeated Member role_changes = 9;
  bool external = 10;                   // true: External Commit của một thiết bị vào nhóm
}
message SubmitCommitResponse { uint64 seq = 1; uint64 new_epoch = 2; }
message SubmitProposalRequest { bytes conv_id = 1; bytes proposal = 2; uint64 mls_epoch = 3; }
message SubmitProposalResponse { uint64 seq = 1; }

message LogEntry {
  uint64 seq = 1;
  EntryKind kind = 2;
  bytes sender_device_id = 3;
  uint64 mls_epoch = 4;
  bytes ciphertext = 5;
  uint64 server_ts_ms = 6;
}
message FetchLogRequest { bytes conv_id = 1; uint64 after_seq = 2; uint32 limit = 3; } // limit tối đa 200
message FetchLogResponse { repeated LogEntry entries = 1; bool more = 2; uint64 head_seq = 3; uint64 epoch = 4; }
message GetGroupInfoRequest { bytes conv_id = 1; }
message GetGroupInfoResponse { bytes group_info = 1; uint64 epoch = 2; }
message ConversationSummary { bytes conv_id = 1; ConvKind kind = 2; uint64 head_seq = 3; uint64 epoch = 4; uint64 last_activity_ms = 5; Role role = 6; }
message ListConversationsRequest { bytes page_token = 1; uint32 limit = 2; }
message ListConversationsResponse { repeated ConversationSummary conversations = 1; bytes next_page_token = 2; }

// ---------- MediaService ----------
service MediaService {
  rpc CreateUpload(CreateUploadRequest) returns (CreateUploadResponse);
  rpc CompleteUpload(CompleteUploadRequest) returns (CompleteUploadResponse);
  rpc GetDownloadUrl(GetDownloadUrlRequest) returns (GetDownloadUrlResponse);
}
message CreateUploadRequest { uint64 size_bytes = 1; bytes ciphertext_sha256 = 2; bool is_public = 3; } // is_public: ảnh đại diện, không mã hóa đầu cuối
message CreateUploadResponse { bytes media_id = 1; repeated string part_urls = 2; uint32 part_size = 3; uint64 expires_ms = 4; }
message CompleteUploadRequest { bytes media_id = 1; repeated string part_etags = 2; }
message CompleteUploadResponse {}
message GetDownloadUrlRequest { bytes media_id = 1; }
message GetDownloadUrlResponse { string url = 1; uint64 expires_ms = 2; }

// ---------- CallService ----------
service CallService {
  rpc StartCall(StartCallRequest) returns (CallTicket);
  rpc JoinCall(JoinCallRequest) returns (CallTicket);
  rpc EndCall(EndCallRequest) returns (EndCallResponse);
}
// CallKind: xem common.proto (mục 4.1)
message StartCallRequest { bytes conv_id = 1; CallKind kind = 2; }
message JoinCallRequest { bytes call_id = 1; }
message CallTicket { bytes call_id = 1; string livekit_url = 2; string token = 3; uint64 mls_epoch = 4; }
message EndCallRequest { bytes call_id = 1; }
message EndCallResponse {}

// ---------- PushService ----------
service PushService {
  rpc RegisterPushToken(RegisterPushTokenRequest) returns (RegisterPushTokenResponse);
  rpc UnregisterPushToken(UnregisterPushTokenRequest) returns (UnregisterPushTokenResponse);
}
enum PushProvider { PUSH_PROVIDER_UNSPECIFIED = 0; PUSH_PROVIDER_FCM = 1; PUSH_PROVIDER_APNS = 2; PUSH_PROVIDER_WEBPUSH = 3; }
message RegisterPushTokenRequest { PushProvider provider = 1; string token = 2; string voip_token = 3; }
message RegisterPushTokenResponse {}
message UnregisterPushTokenRequest {}
message UnregisterPushTokenResponse {}

// ---------- BackupService ----------
service BackupService {
  rpc CreateBackupUpload(CreateBackupUploadRequest) returns (CreateBackupUploadResponse);
  rpc GetLatestBackup(GetLatestBackupRequest) returns (GetLatestBackupResponse);
}
message CreateBackupUploadRequest { uint64 size_bytes = 1; bytes ciphertext_sha256 = 2; }
message CreateBackupUploadResponse { bytes backup_id = 1; repeated string part_urls = 2; uint32 part_size = 3; }
message GetLatestBackupRequest { bytes session_ticket = 1; } // dùng khi chưa có thiết bị (khôi phục tài khoản, 6.14)
message GetLatestBackupResponse { bytes backup_id = 1; string download_url = 2; uint64 size_bytes = 3; uint64 created_ms = 4; }

// ---------- ProfileService ----------
service ProfileService {
  rpc GetProfiles(GetProfilesRequest) returns (GetProfilesResponse);
  rpc UpdateProfile(UpdateProfileRequest) returns (Profile);
  rpc LookupAccount(LookupAccountRequest) returns (LookupAccountResponse);
}
message Profile { bytes account_id = 1; string display_name = 2; bytes avatar_media_id = 3; uint64 updated_ms = 4; }
message GetProfilesRequest { repeated bytes account_ids = 1; }   // tối đa 100; chỉ trả hồ sơ của người chung hội thoại hoặc đã tra bằng LookupAccount
message GetProfilesResponse { repeated Profile profiles = 1; }
message UpdateProfileRequest { string display_name = 1; bytes avatar_media_id = 2; } // avatar_media_id tạo bằng CreateUpload với is_public = true
message LookupAccountRequest { OtpChannel channel = 1; string destination = 2; }     // khớp chính xác số điện thoại hoặc email
message LookupAccountResponse { Profile profile = 1; }                               // không thấy: lỗi NOT_FOUND

// ---------- BlockService ----------
service BlockService {
  rpc BlockAccount(BlockAccountRequest) returns (BlockAccountResponse);
  rpc UnblockAccount(UnblockAccountRequest) returns (UnblockAccountResponse);
  rpc ListBlocked(ListBlockedRequest) returns (ListBlockedResponse);
}
message BlockAccountRequest { bytes account_id = 1; }
message BlockAccountResponse {}
message UnblockAccountRequest { bytes account_id = 1; }
message UnblockAccountResponse {}
message ListBlockedRequest {}
message ListBlockedResponse { repeated bytes account_ids = 1; }
```

**Quy tắc phân quyền ở server.** `SubmitCommit` và `SubmitProposal` chỉ nhận từ thiết bị của tài khoản đang là thành viên; thêm hoặc gỡ thành viên và đổi vai trò (`added`, `removed_account_ids`, `role_changes`) chỉ nhận từ tài khoản có vai trò `ADMIN` hoặc `OWNER` ở bản sao vai trò mà server giữ; `removed_device_ids` cũng cần vai trò đó, trừ khi mọi thiết bị bị gỡ thuộc chính tài khoản gửi (thu hồi thiết bị, mục 6.6). Commit chỉ có path update (xoay khóa, mục 6.8) nhận từ mọi thành viên. Ngoại lệ là Commit có `external = true` do một thiết bị của chính một tài khoản đã là thành viên (mục 6.5), không được kèm thay đổi thành viên hay vai trò, và tin xin rời nhóm (mục 6.4).

## 5. Mã lỗi và quy tắc thử lại

Lỗi trên WebSocket là khung `Error`; lỗi trên Connect RPC là mã Connect tương ứng kèm cùng nội dung `Error` trong phần chi tiết.

| Mã lỗi | Mã Connect | Khi nào | Client xử lý |
| --- | --- | --- | --- |
| `UNAUTHENTICATED` | `unauthenticated` | Token thiếu hoặc hết hạn | Gọi `RefreshToken` rồi thử lại một lần; vẫn lỗi thì đăng nhập lại |
| `PERMISSION_DENIED` | `permission_denied` | Không phải thành viên, thiếu vai trò | Không thử lại, báo cho người dùng |
| `NOT_FOUND` | `not_found` | Hội thoại, media hoặc thiết bị không tồn tại | Không thử lại; xóa tham chiếu cục bộ nếu cần |
| `INVALID_ARGUMENT` | `invalid_argument` | Dữ liệu sai định dạng hoặc vi phạm quy tắc | Không thử lại; ghi log vì đây là lỗi lập trình |
| `RATE_LIMITED` | `resource_exhausted` | Vượt giới hạn tốc độ | Chờ `retry_after_ms` rồi thử lại |
| `EPOCH_MISMATCH` | `failed_precondition` | Epoch gửi lên khác epoch hiện tại | Kéo `FetchLog` tới `head_seq`, áp dụng các Commit, rồi dựng lại và gửi lại (không tính vào backoff, tối đa 5 lần liên tiếp) |
| `ALREADY_EXISTS` | `already_exists` | Tài nguyên đã có | Coi là thành công nếu cùng nội dung |
| `DEVICE_REVOKED` | `permission_denied` | Thiết bị đã bị thu hồi | Như mã đóng 4003 |
| `VERSION_UNSUPPORTED` | `failed_precondition` | Phiên bản giao thức quá cũ | Yêu cầu cập nhật app |
| `PAYLOAD_TOO_LARGE` | `invalid_argument` | Vượt giới hạn kích thước | Không thử lại; chuyển nội dung lớn qua media |
| `UNAVAILABLE` | `unavailable` | Server quá tải hoặc đang drain | Thử lại với backoff |

**Quy tắc thử lại**

- Mọi lần thử lại dùng đúng `client_msg_id` (tin nhắn) hoặc `Idempotency-Key` (RPC) của lần đầu, nên thử lại luôn an toàn.
- Backoff bắt đầu từ 0,5 giây, nhân đôi, tối đa 30 giây, cộng jitter ±50%.
- Tin ở trạng thái đang gửi được thử lại tới 24 giờ; sau đó chuyển sang `FAILED` và để người dùng gửi lại.
- Lỗi `INVALID_ARGUMENT` và `PERMISSION_DENIED` không bao giờ thử lại tự động.

## 6. Các luồng MLS

Ký hiệu: A1, A2, A3 là các thiết bị của Alice; B1, B2 của Bob; C1 của Carol. DS (Delivery Service) là server. Mọi RPC kèm token xác thực. Server chỉ xử lý các thông điệp MLS ở mức chuyển tiếp và kiểm tra những gì nó đọc được (xem từng luồng); phần còn lại là ciphertext.

### 6.1 Đăng ký thiết bị

Tiền điều kiện: đã `VerifyOtp` và có `session_ticket`.

1. Thiết bị sinh `device_id` (UUIDv7) và cặp khóa ký Ed25519 của thiết bị.
2. Nếu là thiết bị đầu tiên của tài khoản, sinh thêm khóa danh tính tài khoản (Ed25519) và cất trong keystore. Thiết bị sau không sinh mà nhận khóa này qua luồng 6.5.
3. Tạo credential: `BasicCredential` có identity gồm `account_id`, `device_id`, khóa công khai của thiết bị và thời điểm tạo, kèm chữ ký của khóa danh tính tài khoản lên các trường đó.
4. Sinh 100 KeyPackage dùng một lần (hạn 30 ngày) và 1 KeyPackage last resort (hạn 90 ngày), mỗi gói ký bằng khóa thiết bị.
5. Gọi `RegisterDevice`. Server kiểm tra ticket còn hạn, chữ ký credential đúng với khóa danh tính tài khoản (ở thiết bị đầu tiên, khóa trong request), mỗi KeyPackage hợp lệ về định dạng, chữ ký và credential khớp, kích thước và số lượng nằm trong giới hạn.
6. Server trả cặp token; thiết bị kết nối WebSocket.

**Bổ sung KeyPackage.** Thiết bị gọi `CountKeyPackages` khi kết nối và mỗi 24 giờ; còn dưới 20 gói thì tải lên thêm 100.

### 6.2 Tạo hội thoại 1-1 hoặc nhóm

Ví dụ: A1 tạo hội thoại 1-1 với Bob (hai thiết bị B1, B2); Alice còn thiết bị A2.

1. A1 gọi `FetchKeyPackages([alice, bob])`. Server trả một KeyPackage cho mỗi thiết bị còn hiệu lực của hai tài khoản và tiêu thụ gói một lần; hết gói một lần thì trả gói last resort và đánh dấu `last_resort`. A1 bỏ gói của chính mình.
2. A1 kiểm tra: credential của từng thiết bị được khóa danh tính tài khoản ký đúng; khóa danh tính của Bob khớp lần đã thấy trước (lần đầu thì ghi nhận, lần sau khác thì cảnh báo người dùng); bỏ qua thiết bị có `revocation_statements` hợp lệ.
3. A1 tạo nhóm MLS với `group_id` ngẫu nhiên 32 byte. Group context extension chứa `chat_policy`: bảng vai trò theo tài khoản, cờ cho phép External Commit của cùng một tài khoản, thời gian tự hủy tin, và tên nhóm (nếu là nhóm). A1 thêm A2, B1, B2 bằng một Commit, sinh Welcome cho từng thiết bị mới và `GroupInfo`.
4. A1 gọi `CreateConversation` với `kind`, `group_id`, `members` (hội thoại 1-1: cả hai là `MEMBER`; nhóm: người tạo là `OWNER`), `commit`, `welcomes`, `group_info`.
5. Server kiểm tra: người gọi nằm trong `members`; mọi `recipient_device_id` thuộc tài khoản trong `members`; hội thoại 1-1 có đúng hai tài khoản. Nếu hai tài khoản đã có hội thoại 1-1, server trả `existed = true` kèm `conv_id` cũ và không ghi gì; client bỏ nhóm vừa tạo và vào hội thoại cũ theo luồng 6.5.
6. Nếu là hội thoại mới, server tạo `conv_id`, ghi Commit vào `conv_log` ở `seq = 1`, đặt `epoch = 1` trong `conv_head`, ghi Welcome vào hộp thư của từng thiết bị nhận (kind `WELCOME`, ciphertext nằm trực tiếp trong mục hộp thư), lưu `GroupInfo`, cập nhật `members_by_conv` và `convs_by_account`, rồi trả `conv_id`, `seq = 1`, `epoch = 1`.
7. Mỗi thiết bị nhận `Deliver` kind `WELCOME`, xử lý Welcome để vào nhóm ở epoch 1, lưu trạng thái rồi gửi `Ack`.

**Chống spam.** `CreateConversation` tới người chưa là liên hệ bị giới hạn (khởi điểm 20 hội thoại mới mỗi ngày mỗi tài khoản). Hội thoại từ người lạ hiện ở mục tin nhắn chờ phía người nhận cho tới khi họ chấp nhận; đây là chính sách client, server không can thiệp.

### 6.3 Thêm thành viên và tranh chấp epoch

Ví dụ: A1 (vai trò `ADMIN`) thêm Carol (C1) vào nhóm đang ở epoch 7.

1. A1 gọi `FetchKeyPackages([carol])` và kiểm tra như bước 2 của mục 6.2.
2. A1 dựng Add proposal cho từng thiết bị của Carol và một Commit, sinh Welcome cho thiết bị mới và `GroupInfo` của epoch 8. Một Commit thêm tối đa 50 thiết bị; nhiều hơn thì chia thành nhiều Commit.
3. A1 gọi `SubmitCommit(expected_epoch = 7, commit, welcomes, group_info, added = [carol: MEMBER])`.
4. Server kiểm tra A1 có vai trò `ADMIN` hoặc `OWNER` ở bản sao vai trò, và mọi Welcome đi tới thiết bị của tài khoản nằm trong `added`.
5. Server ghi bằng một giao dịch có điều kiện `conv_head.epoch == 7`: tăng `head_seq`, đặt epoch 8, ghi Commit vào `conv_log`, ghi Welcome vào hộp thư các thiết bị của Carol. Con trỏ hộp thư của các thiết bị hiện có được ghi ngay sau đó qua hàng đợi bền (JetStream), idempotent theo `(conv_id, seq)`, vì một giao dịch DynamoDB có giới hạn số mục (100 tại thời điểm viết, cần xác minh).
6. Thiết bị hiện có nhận `Deliver` kind `COMMIT` và áp dụng theo `seq`; thiết bị của Carol nhận Welcome và vào nhóm ở epoch 8.

Hai admin có thể cùng dựng Commit trên epoch 7. Chỉ một Commit thắng vì điều kiện `epoch == 7` chỉ thỏa một lần; bên thua nhận `EPOCH_MISMATCH` kèm `current_epoch`, đồng bộ qua `FetchLog`, áp dụng Commit đã thắng rồi dựng lại nếu thay đổi của mình vẫn còn cần.

&#91;embedded content: tranh chấp epoch · ví dụ hai admin cùng Commit\]

Hai quy tắc đi kèm. Thứ nhất, `SendMessage` mang epoch cũ cũng bị từ chối với `EPOCH_MISMATCH`, nên mọi tin trong `conv_log` đều thuộc đúng epoch của vị trí `seq` đó và client không cần giữ khóa của các epoch trước. Thứ hai, client áp dụng Commit đúng theo `seq`, không bỏ qua và không đảo thứ tự.

### 6.4 Gỡ thành viên và rời nhóm

**Gỡ thành viên.** Admin dựng Remove proposal cho mọi thiết bị của tài khoản bị gỡ rồi một Commit, và gọi `SubmitCommit` với `removed_account_ids`. Server cập nhật `members_by_conv` và dừng ghi con trỏ hộp thư cho các thiết bị đó từ `seq` mới. Server vẫn gửi Commit này cho thiết bị bị gỡ như tin cuối để họ biết mình đã bị gỡ; thiết bị đó không có khóa của epoch mới.

**Rời nhóm.** MLS không cho thành viên tự gỡ chính mình, nên luồng gồm hai bước:

1. Thiết bị gọi `SubmitProposal` với Remove proposal cho chính mình. Server đánh dấu tài khoản là đang rời, ngừng gửi push của hội thoại này tới tài khoản đó.
2. Client của một admin đang online tự động dựng Commit gỡ lá đó. Nếu 60 giây (cộng jitter) không có admin nào làm, thành viên bất kỳ được phép làm, nhờ cờ `chat_policy` cho phép commit việc tự rời.

Chủ nhóm (`OWNER`) phải chuyển quyền trước khi rời; client không cho phép bỏ qua bước này.

### 6.5 Thêm thiết bị mới vào tài khoản đã có

Ví dụ: A3 là thiết bị mới của Alice, A1 là thiết bị đã được tin cậy.

1. A3 sinh `device_id`, cặp khóa ký và cặp khóa X25519 tạm, gọi `StartLink` và nhận `link_id`, `short_code` (6 chữ số, hạn 5 phút). A3 hiển thị mã QR chứa `link_id`, khóa công khai của thiết bị, khóa X25519 tạm và `short_code`.
2. A1 quét QR. Khi người dùng xác nhận `short_code` khớp ở cả hai máy, A1 gọi `ApproveLink` với credential ký cho A3 (bằng khóa danh tính tài khoản) và `sealed_bundle`: khóa danh tính tài khoản, mã hóa bằng ECDH giữa khóa tạm của A1 và khóa tạm của A3 cùng một thuật toán mã hóa có xác thực.
3. A3 gọi `CompleteLink` (chờ tối đa 30 giây), nhận credential, `sealed_bundle` và `session_ticket`, rồi giải `sealed_bundle`.
4. A3 gọi `RegisterDevice` như luồng 6.1, không gửi `account_identity_public_key`.
5. Với mỗi hội thoại trong `ListConversations`, ưu tiên hoạt động gần nhất, tối đa 4 hội thoại song song: A3 gọi `GetGroupInfo`, dựng External Commit (kèm path update) để tự vào nhóm, rồi `SubmitCommit(expected_epoch = epoch của GroupInfo, external = true)`. Nếu gặp `EPOCH_MISMATCH` thì lấy lại `GroupInfo` và thử lại, tối đa 5 lần với backoff.
6. Server kiểm tra tài khoản của A3 đã là thành viên (`members_by_conv`), thiết bị chưa bị thu hồi, và credential của lá mới được khóa danh tính tài khoản (server đã lưu khóa công khai này) ký đúng. Commit external là `PublicMessage` nên server đọc được lá mới để kiểm tra. Nếu hợp lệ, ghi như `SubmitCommit` thường nhưng không đòi vai trò admin.
7. Các thành viên hiện có áp dụng Commit sau khi tự kiểm tra cùng điều kiện (cờ `chat_policy` cho phép, lá mới cùng tài khoản đã là thành viên). Server và client dùng cùng quy tắc để không tạo nhánh khác nhau của nhóm.
8. A3 không đọc được tin cũ theo mặc định. Chuyển lịch sử từ A1 hoặc khôi phục backup nằm ngoài tài liệu này (xem mục 10 của tài liệu chính).

Sau bước 2, A1 không cần online nữa. Đây là điểm khác với mô tả ở mục 10 tài liệu chính (thiết bị cũ lần lượt thêm thiết bị mới vào từng nhóm); xem mục 9.

### 6.6 Thu hồi thiết bị

1. Từ một thiết bị còn tin cậy (A1), người dùng chọn thu hồi A3. A1 tạo `revocation_statement` gồm `device_id` và thời điểm thu hồi, ký bằng khóa danh tính tài khoản.
2. A1 gọi `RevokeDevice`. Server đánh dấu thu hồi, đóng kết nối của A3 bằng mã 4003, vô hiệu token, xóa KeyPackage còn lại của A3, ngừng ghi hộp thư cho A3, và lưu statement vào key directory (trả về trong `FetchKeyPackages.revocation_statements`).
3. A1 (hoặc thiết bị khác của Alice) gỡ A3 khỏi từng nhóm bằng Remove proposal và Commit với `removed_device_ids`, ưu tiên hội thoại gần đây.
4. Client của các thành viên khác kiểm tra statement trước khi tin rằng Commit gỡ thiết bị là hợp lệ.

**Rủi ro cần biết.** Cho tới khi A3 bị gỡ khỏi một nhóm, A3 vẫn là lá trong cây MLS của nhóm đó và còn giữ khóa của epoch hiện tại. Server đã chặn A3 nhận tin mới, nhưng một kẻ đang giữ A3 và chặn được ciphertext vẫn có thể giải mã tin của epoch đó. Việc gỡ A3 khỏi nhóm (luồng bước 3) là lúc khóa mới thật sự loại A3, vì vậy bước này cần làm sớm.

### 6.7 Vào lại nhóm khi lạc đồng bộ

Khi nào: thiết bị offline quá TTL nên `FetchLog` không còn các Commit đã bỏ lỡ; giải mã thất bại liên tiếp 3 lần; hoặc trạng thái MLS cục bộ của nhóm bị mất (ví dụ sau khôi phục backup).

1. Client xóa trạng thái MLS cục bộ của nhóm, giữ lại lịch sử đã đọc.
2. Client gọi `GetGroupInfo` và dựng External Commit kiểu resync, loại lá cũ của chính thiết bị này ngay trong Commit, rồi `SubmitCommit(external = true)`.
3. Tin trong khoảng bị lỡ không đọc được lại (forward secrecy). Giao diện hiển thị "một số tin không còn khả dụng".
4. Để tránh bão Commit, mỗi thiết bị chỉ resync tối đa 3 lần mỗi giờ cho mỗi nhóm.

### 6.8 Xoay khóa định kỳ

Post-compromise security chỉ có khi có Commit mang path update. Quy tắc khởi điểm:

- Thiết bị đang hoạt động gửi một Commit chỉ chứa path update sau 24 giờ kể từ lần cuối nếu nhóm có tối đa 20 thiết bị, hoặc sau 7 ngày với nhóm lớn hơn. Thời điểm cộng jitter ngẫu nhiên 0-24 giờ.
- Nếu gặp `EPOCH_MISMATCH` thì bỏ lượt này và thử lại ở chu kỳ sau, không chen vào các Commit khác.
- KeyPackage last resort được thay mới mỗi 90 ngày.

Các tham số này cần đo trong PoC MLS: mục tiêu là tránh biến nhóm lớn thành chuỗi Commit liên tục.

### 6.9 Cuộc gọi

1. A1 gọi `StartCall(conv_id, kind)`. Server kiểm tra A1 là thành viên, tạo `call_id` và phòng LiveKit, cấp token ngắn hạn, và đặt `mls_epoch` hiện tại của hội thoại vào `CallTicket`. Server gửi VoIP push (iOS) hoặc FCM ưu tiên cao (Android) tới thiết bị của các thành viên khác. Payload chỉ có `call_id` và `conv_id`; thiết bị tra tên người gọi ở DB cục bộ.
2. Mỗi thiết bị muốn tham gia gọi `JoinCall(call_id)` và nhận token LiveKit.
3. Khóa SFrame của epoch `e` là `K_e = MLS-Exporter(label = "chat.call.v1", context = call_id, length = 32)`. Thiết bị chỉ vào cuộc gọi khi epoch cục bộ bằng `mls_epoch` trong ticket; nếu lệch thì đồng bộ trước.
4. Khi epoch đổi giữa cuộc gọi (có người vào hoặc ra nhóm), mỗi thiết bị tính khóa mới, đặt chỉ số khóa kế tiếp và giữ khóa cũ khoảng 10 giây để giải mã khung còn đang bay.
5. Kết thúc cuộc gọi: `EndCall`, rồi một thiết bị gửi tin điều khiển `CallEvent` (kết thúc, thời lượng) vào hội thoại.

Cuộc gọi dùng toàn bộ thành viên của hội thoại; gọi một tập con của nhóm cần một nhóm MLS riêng cho cuộc gọi đó, như đã nêu ở mục 12 tài liệu chính.

### 6.10 Cuộc gọi đến khi app đang mở

Khi `StartCall` thành công, server đẩy khung `IncomingCall` (`call_id`, `conv_id`, `kind`, `caller_account_id`, `started_ms`) tới mọi thiết bị của các thành viên khác đang có kết nối WebSocket. Thiết bị đóng kết nối vẫn nhận push như 6.9. Khi một thiết bị của cùng tài khoản trả lời `JoinCall`, các thiết bị còn lại dừng chuông. Khung này không ghi vào hộp thư và không cần `Ack`; lịch sử cuộc gọi vẫn lấy từ `CallEvent` như cũ.

### 6.11 Đăng nhập bằng passkey

Passkey là cách thay cho bước OTP, không thay cho việc chứng minh thiết bị. Đăng ký: thiết bị đã đăng nhập gọi `BeginPasskeyRegistration`, thực hiện WebAuthn trên thiết bị, rồi gọi `FinishPasskeyRegistration` kèm tên gợi nhớ. Đăng nhập: thiết bị chưa đăng nhập gọi `BeginPasskeyLogin` (không cần nhập số hay email), ký thách thức, rồi gọi `FinishPasskeyLogin` để nhận `session_ticket` giống `VerifyOtp`. Phần còn lại giữ nguyên: thiết bị đầu tiên gọi `RegisterDevice`; thiết bị thêm vào tài khoản có sẵn đi tiếp qua liên kết thiết bị (6.5).

### 6.12 Hồ sơ và tìm người

Hồ sơ (tên hiển thị, ảnh đại diện) do server lưu dạng thường trong PostgreSQL, nên server thấy được. Ảnh đại diện tải lên bằng `CreateUpload` với `is_public = true`: không mã hóa đầu cuối, mọi người dùng đã đăng nhập đều tải được qua `GetDownloadUrl`. `GetProfiles` chỉ trả hồ sơ của người chung hội thoại với người gọi hoặc người vừa được tra bằng `LookupAccount`.

Tìm người để nhắn chỉ bằng `LookupAccount` với số điện thoại hoặc email nhập chính xác. Bản 1 không đồng bộ danh bạ và không tìm theo tên. Server giới hạn số lần tra mỗi tài khoản để chống dò số (trả `RATE_LIMITED`), và trả `NOT_FOUND` khi không có tài khoản.

### 6.13 Chặn người dùng

Danh sách chặn nằm ở server. Với người bị chặn, server từ chối `CreateConversation` 1-1 và `StartCall` bằng lỗi `NOT_FOUND` (không lộ việc bị chặn), và ngừng gửi push cho người chặn. Với hội thoại 1-1 đã có, server vẫn ghi vào `conv_log` vì không đọc được nội dung; client của người chặn ẩn hội thoại và bỏ qua tin đến. Chặn không áp dụng cho nhóm: hai người cùng trong một nhóm vẫn thấy nhau như bình thường.

### 6.14 Khôi phục tài khoản khi mất hết thiết bị

Người dùng đăng nhập lại bằng OTP hoặc passkey để có `session_ticket`. Thiết bị gọi `GetLatestBackup` kèm `session_ticket` (chưa có token vì chưa có thiết bị). Có bản sao lưu: client tải về, giải mã bằng khóa sao lưu của người dùng, lấy lại khóa danh tính tài khoản và lịch sử, rồi `RegisterDevice` như bình thường. Không có bản sao lưu: client tạo khóa danh tính mới và gọi `RegisterDevice` với `reset_identity = true`; tài khoản giữ nguyên nhưng mọi tin cũ mất. Server tin khóa mới vì tài khoản vừa qua OTP hoặc passkey, ghi nhận khóa này là khóa danh tính hiện tại của account\_id và chấp nhận External Commit (6.5) của thiết bị mới vào mọi cuộc trò chuyện mà account\_id đang là thành viên (PoC 05/11/2026: External Commit với khóa ký mới không tự gỡ leaf cũ, chỉ resync với cùng khóa ký mới tự gỡ). Quy tắc client: khi xử lý một External Commit có credential trùng account\_id với một leaf hiện có nhưng khác khóa ký, thành viên có leaf index nhỏ nhất đang online gửi Commit Remove leaf cũ; không thêm RPC hay khung mới. Client của người khác chấp nhận ngay và không hiện cảnh báo. Đây là rủi ro đã chấp nhận: ai chiếm được số điện thoại (ví dụ qua SIM swap) có thể mạo danh người dùng mà không ai biết; Key Transparency ở giai đoạn 4 sẽ giảm rủi ro này.

## 7. Máy trạng thái và nội dung bên trong MLS

### 7.1 Tin nhắn gửi đi

Tin được lưu dạng plaintext trong outbox SQLCipher và chỉ mã hóa vào đúng lúc gửi, vì epoch có thể đổi giữa lúc soạn và lúc gửi.

| Trạng thái | Vào khi | Chuyển sang |
| --- | --- | --- |
| `PENDING` | Người dùng bấm gửi; đã ghi outbox | `SENDING` khi có kết nối |
| `SENDING` | Đã mã hóa theo epoch hiện tại và gửi `SendMessage` | `SENT` khi có `SendResult`; về `PENDING` khi mất kết nối, quá 10 giây không phản hồi, hoặc `EPOCH_MISMATCH` (sau khi đồng bộ) |
| `SENT` | Nhận `SendResult` (đã có `seq`) | `DELIVERED` |
| `DELIVERED` | Nhận `DeliveredReceipt` từ ít nhất một thiết bị của người nhận | `READ` |
| `READ` | Nhận tin điều khiển `ReadUpTo` có `seq` không nhỏ hơn `seq` của tin | Trạng thái cuối |
| `FAILED` | Quá 24 giờ thử lại, hoặc gặp lỗi không thử lại được | `PENDING` khi người dùng bấm gửi lại (dùng `client_msg_id` mới) |

### 7.2 Tin nhận về và kết nối

Tin nhận về đi qua chuỗi `RECEIVED`, `BUFFERED` (chờ khoảng trống `seq`, tối đa 5 giây), `DECRYPTED`, `STORED`, `ACKED`. Nếu giải mã thất bại, client lưu một chỗ giữ chỗ "không giải mã được", ghi log và bắt đầu vào lại nhóm theo mục 6.7.

| Trạng thái kết nối | Vào khi | Chuyển sang |
| --- | --- | --- |
| `DISCONNECTED` | Khởi động hoặc đã đóng | `CONNECTING` khi có mạng |
| `CONNECTING` | Đang mở WSS | `AUTHENTICATING` khi mở xong; `BACKOFF` khi lỗi |
| `AUTHENTICATING` | Đã gửi `Hello` | `SYNCING` khi nhận `Welcome`; `BACKOFF` nếu đóng với 4001, 4002, 4009 |
| `SYNCING` | Đang nhận tồn đọng | `ONLINE` khi nhận `SyncDone` |
| `ONLINE` | Kết nối bình thường | `BACKOFF` khi mất kết nối |
| `BACKOFF` | Chờ trước khi thử lại | `CONNECTING` khi hết thời gian chờ |

Các mã 4003 và 4004 đưa client ra khỏi vòng này (xóa dữ liệu hoặc yêu cầu cập nhật); mã 4010 giữ ở `DISCONNECTED`.

### 7.3 Nội dung bên trong MLS

Mọi `ciphertext` ở WebSocket và `conv_log` là một `MLSMessage` mà plaintext của nó là `Payload` dưới đây. Server không đọc được và không biết loại nội dung. Plaintext được đệm ngẫu nhiên lên bội số của 256 byte trước khi mã hóa để giảm lộ độ dài tin.

```protobuf
message Payload {
  uint32 version = 1;
  bytes client_msg_id = 2;      // trùng SendMessage.client_msg_id; dùng để tham chiếu tin
  uint64 sent_at_ms = 3;        // đồng hồ máy người gửi, chỉ để hiển thị
  bytes reply_to = 4;           // client_msg_id của tin được trả lời, nếu có
  oneof content {
    TextContent text = 10;
    MediaContent media = 11;
    Reaction reaction = 12;
    Edit edit = 13;
    Delete delete = 14;
    ReadUpTo read_up_to = 15;
    Typing typing = 16;
    CallEvent call_event = 17;
  }
}
message TextContent { string body = 1; }
message MediaContent {
  bytes media_id = 1; bytes key = 2; bytes nonce_prefix = 3; bytes ciphertext_sha256 = 4;
  uint64 size_bytes = 5; string mime = 6; string file_name = 7; string caption = 8;
  uint32 width = 9; uint32 height = 10; uint32 duration_ms = 11;
  bytes thumbnail = 12; string blurhash = 13;
}
message Reaction { bytes target = 1; string emoji = 2; bool remove = 3; }
message Edit { bytes target = 1; string new_body = 2; }
message Delete { bytes target = 1; }
message ReadUpTo { uint64 seq = 1; }
message Typing { bool active = 1; }   // gửi với ephemeral = true
message CallEvent {
  enum Kind { KIND_UNSPECIFIED = 0; KIND_STARTED = 1; KIND_ENDED = 2; KIND_MISSED = 3; }
  bytes call_id = 1; Kind kind = 2; uint32 duration_ms = 3;
}
```

`Edit` và `Delete` chỉ có hiệu lực nếu người gửi tin gốc trùng người gửi `Edit` hoặc `Delete`, và client người nhận tự kiểm tra điều đó; server không tham gia.

## 8. Ánh xạ sang PoC và cách kiểm thử

Bảng dưới nối các PoC ở mục 16 của tài liệu chính với phần đặc tả cần có để chạy chúng.

| PoC | Phần đặc tả liên quan | Kịch bản tối thiểu |
| --- | --- | --- |
| MLS đa nền tảng | 6.1, 6.2, 6.3, 6.5, 6.7, 6.8 | Chạy trên ba nền tảng (Android, Web, desktop): tạo 1-1, tạo nhóm 100 và 1.000 thiết bị mô phỏng, thêm và gỡ thành viên, hai admin cùng Commit, một thiết bị mới vào 50 nhóm bằng External Commit, resync, khôi phục không có bản sao lưu (máy mới có khóa danh tính mới vào lại 50 nhóm bằng External Commit và gỡ được leaf cũ của cùng tài khoản), và đo giới hạn 50 thiết bị mỗi Commit, 1.000 thiết bị mỗi nhóm |
| Gọi video E2EE | 6.9 | Cuộc gọi 4 người trên các nền tảng; đổi epoch giữa cuộc gọi bằng cách thêm và gỡ một thành viên |
| Tải gateway | 2, 3 | Client giả lập viết bằng Go: 10.000 kết nối trên máy cục bộ (ngoại suy ra 100.000), bắt tay, heartbeat, 1.000 `SendMessage` mỗi giây, rồi cho server đóng đồng loạt với mã 4009 để đo bão kết nối lại |
| Flutter Web + WASM | 7.3 | Lưu và tìm kiếm tin cục bộ trên OPFS khi chạy lõi Rust ở Web Worker |

**Bất biến cần kiểm tra trong mọi kịch bản**

1. Sau khi áp dụng cùng một chuỗi Commit theo `seq`, mọi thành viên có cùng epoch và cùng giá trị exporter secret.
2. Mỗi `seq` có đúng một mục trong `conv_log`, và không có hai Commit nào cùng được chấp nhận ở một epoch.
3. Mọi tin trong `conv_log` giải mã được bằng khóa của đúng epoch tại `seq` đó.
4. Thiết bị đã bị gỡ khỏi nhóm không giải mã được tin ở các epoch sau lần gỡ.
5. Gửi lại với cùng `client_msg_id` không bao giờ tạo thêm một mục trong `conv_log`.

**Kiểm thử cần có**

- Bộ mô phỏng nhiều thiết bị chạy các luồng ở mục 6 với một server giả, kiểm tra các bất biến trên.
- Chèn lỗi: mất kết nối giữa lúc gửi `SubmitCommit` và lúc nhận phản hồi; sập server giữa giao dịch ghi Commit và lúc ghi con trỏ hộp thư (công việc sửa chữa phải hoàn tất việc ghi con trỏ).
- Kiểm thử thuộc tính cho mã hóa và giải mã Protobuf, và `buf breaking` trong CI để chặn thay đổi gây vỡ tương thích.
- Test vector của RFC 9420 cho thư viện MLS đang dùng. Tiêu chí đạt của PoC MLS: mọi bất biến trên đúng trên cả ba nền tảng; ca khôi phục không có bản sao lưu đã chạy trên Windows ngày 05/11/2026: External Commit thêm leaf mới, leaf cũ phải được gỡ bằng Remove (đã kiểm chứng), resync cùng khóa ký tự gỡ; nhóm 1.000 thiết bị, mỗi Commit thêm 50: Commit cuối 92 KB, tạo 33 ms, nhận 11 ms, đạt. PoC tải gateway 05/11/2026 (loopback, không TLS): 10.000 kết nối, p95 0,33 ms, 67 MB máy chủ, ngoại suy 100.000 kết nối khoảng 650 MB, đạt. WASM (06/11/2026, Chrome 156 và Node trên Windows): cùng kết quả chức năng; ở 1.000 thiết bị tạo Commit 155 ms, nhận 17 ms, chậm hơn native khoảng 5 lần khi tạo và 1,5 lần khi nhận, vẫn chấp nhận được. PoC Web (06/11/2026, Chrome 156, JavaScript thuần): SQLite trên OPFS trong Web Worker với COOP/COEP (crossOriginIsolated = true) lưu 1.000.000 tin, còn nguyên sau khi tải lại trang; tìm FTS5 p50 3,5 ms, p95 5,4 ms, tối đa 14 ms (tiêu chí dưới 200 ms, đạt); tải 50 tin mới nhất p95 24 ms; MLS WASM chạy cùng Worker. PoC video E2EE (06/11/2026, LiveKit chạy trong Docker, 4 cửa sổ Chrome và thêm một cửa sổ không mã hóa làm đối chứng): xoay khóa khi có người vào hoặc ra; thiết bị vào giữa cuộc gọi nhận khóa mới nhất và giải mã ngay; hơn 10 phút, 0 giây mất tiếng; mỗi lần xoay có 1 đến 4 khung lỗi giải mã (vài chục ms), không có lỗi kéo dài; cửa sổ không mã hóa chỉ thấy nhiễu và các cửa sổ có khóa từ chối khung của nó, đạt. Quy tắc rút ra cho client: bên gửi chuyển sang khóa mới sau khi gửi xong Commit khoảng 1 giây, bên nhận giữ cả khóa cũ và khóa mới theo chỉ số khóa. Khóa SFrame từ exporter("call", call\_id, 32) (06/11/2026, Windows): cùng epoch thì các bên giống nhau, đổi epoch thì khác, người đã bị gỡ không có khóa mới, khác call\_id thì khác khóa, đạt. Android (06/11/2026, emulator x86\_64 Android 17 trang nhớ 16 KB, binary Rust biên dịch bằng NDK 30): cùng kết quả chức năng, External Commit với khóa mới vẫn cần Remove để gỡ leaf cũ, resync tự gỡ; ở 952 thiết bị tạo Commit 98 ms, nhận 24 ms, kích thước 88,7 KB, chậm hơn Windows khoảng 3 lần khi tạo và 2 lần khi nhận, trong ngưỡng chấp nhận, đạt. Cầu nối Dart và JavaScript trong Flutter Web (06/11/2026, Chrome, Web Worker qua dart:js\_interop): nhị phân 100 KB đi và về nguyên vẹn (21 ms); MLS chạy trong Worker cho cùng kết quả chức năng; ở 1.000 thiết bị tạo Commit 162 ms, nhận 17 ms, Commit 92 KB, bằng số đo WASM thuần, cầu nối không thêm độ trễ đáng kể, đạt. Chưa kiểm tra: máy ARM thật, Commit thêm 1 thiết bị, kích thước Welcome; các con số 50 thiết bị mỗi Commit và 1.000 thiết bị mỗi nhóm đã được xác nhận bằng số đo trên Windows, WASM và Android (điểm mở 6 đã đóng).

## 9. Điểm mở và đề xuất cập nhật tài liệu chính

**Điểm mở (không chặn 1.0.0)**

1. **Nội dung push.** Kích thước payload push bị giới hạn (khoảng 4 KB với FCM, chưa đo; APNs để sau cùng iOS). Đã chốt cách dự phòng: chỉ gửi kèm ciphertext khi đủ nhỏ, ngược lại chỉ gửi tín hiệu rồi client kéo về; ngưỡng cụ thể đo trong giai đoạn phát triển, không cần PoC riêng.
2. **Chuyển lịch sử giữa thiết bị.** Giao thức chuyển gói lịch sử từ A1 sang A3 qua kênh mã hóa chưa được đặc tả.
3. **Tin tự hủy.** Thời gian tự hủy nằm trong `chat_policy` và do client thi hành; cần chốt hành vi khi thành viên đổi chính sách.
4. **Siêu dữ liệu nhóm.** Tên và ảnh nhóm nằm trong group context extension; cần chốt cách đưa ảnh nhóm (qua media) vào extension.
5. **Khóa danh tính tài khoản đổi.** Việc khôi phục tài khoản và đổi khóa danh tính phụ thuộc vòng đời tài khoản trong backlog 1.1, cùng với Key Transparency ở giai đoạn 4.

**Điều chỉnh đã đưa vào tài liệu chính (bản 1.3.0)**

| Mục chính | Thay đổi |
| --- | --- |
| 7 | Thay đoạn proto bằng tham chiếu tới tài liệu này |
| 8 | Thêm kiểm tra epoch cho `SendMessage`; Commit và Welcome đi qua `SubmitCommit`; con trỏ hộp thư ghi sau giao dịch qua hàng đợi bền |
| 9 | Server kiểm tra credential của External Commit (là `PublicMessage`); thêm bảng vai trò mà server giữ |
| 10 | Thiết bị mới tự vào nhóm bằng External Commit (6.5), thay cho mô tả thiết bị cũ lần lượt thêm vào |
| 13 | `members_by_conv có trạng thái đang rời (bảng conv_head đã có epoch)`; thêm bảng `device_links` (TTL 5 phút) và `revocations` |
| 17 | Thêm hai quyết định: kiểm tra epoch ở server, và External Commit cho thiết bị mới |
| 7, 12 | Thêm passkey, ProfileService, BlockService, khung IncomingCall, cờ reset\_identity và is\_public; ảnh đại diện không mã hóa là ngoại lệ duy nhất của nguyên tắc server chỉ chuyển ciphertext |

**Phiên bản.** Tài liệu này là 1.1.0 (bản 1.1.0 làm rõ phân quyền `SubmitCommit` và thêm giới hạn Commit, GroupInfo, Welcome từ giai đoạn 2, xem ADR 0004; bản 0.2.0 bổ sung passkey, hồ sơ và tìm người, chặn người dùng, khung cuộc gọi đến và khôi phục tài khoản; bản 1.0.0 chốt sau khi các PoC đạt). Các điều chỉnh trên đã đưa vào tài liệu chính 1.3.0 ngày 06/11/2026 (tài liệu chính 1.1.0 và 1.2.0 đã phát hành với các quyết định bổ sung ở bản 0.2.0 của tài liệu này).
