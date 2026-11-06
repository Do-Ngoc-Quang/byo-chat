# server

Backend Go (giai đoạn 2: server tối thiểu). Spec: `docs/spec/giao-thuc.md` (mục 3 WebSocket, 4.2 `ConversationService`, 5 lỗi, 6.2-6.5 luồng, 8 kiểm thử), `docs/spec/thiet-ke-chinh.md` (mục 8 luồng tin, 13 mô hình dữ liệu). Quyết định: ADR 0004.

## Bố cục
| Đường dẫn | Việc |
|---|---|
| `cmd/gateway/` | Tiến trình: Gateway WebSocket + Connect RPC + Message Service + worker fanout |
| `internal/gateway/` | WebSocket: `Hello`, `Welcome`, tồn đọng, `SyncDone`, `Ack`, heartbeat, mã đóng 4001-4010 |
| `internal/message/` | Message Service: `SendMessage`, `SubmitCommit`, `CreateConversation`, `FetchLog`, fanout, sửa chữa |
| `internal/api/` | `ConversationService` qua Connect RPC (Bearer, `Idempotency-Key`, mã lỗi) |
| `internal/store/` | Interface `MetaStore`, `MailboxStore`; `memory/`, `dynamo/`, `postgres/` (+ `migrations/`), `storetest/` (hợp đồng chung) |
| `internal/natsx/` | Bus (NATS `dev.<device_id>`) và hàng đợi bền (JetStream) |
| `internal/auth/` | Token HMAC cho dev/test (đăng nhập thật ở giai đoạn 3) |
| `internal/app/` | Ghép các thành phần; dùng chung cho `cmd/` và test tích hợp |
| `gen/` | Mã sinh từ `proto/` (không commit) |

## Lệnh
```bash
# sinh mã Go từ proto (cần protoc-gen-go, protoc-gen-connect-go trong PATH)
cd proto && buf generate --template buf.gen.server.yaml
# kiểm tra
cd server && go vet ./... && go test -race ./...
```
Test chỉ dùng bộ nhớ khi không đặt biến môi trường. Để chạy trên hạ tầng thật: xem `dev/README.md` (`TEST_POSTGRES_DSN`, `TEST_DYNAMO_ENDPOINT`; NATS JetStream chạy nhúng trong test).

## Chưa làm ở giai đoạn 2
Xem mục "Giới hạn" trong `docs/notes.md` (phiên giai đoạn 2).
