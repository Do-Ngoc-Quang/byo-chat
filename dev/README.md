# dev

Môi trường phát triển cục bộ: `docker-compose.yml` (Postgres, DynamoDB local, NATS JetStream, Valkey) và script trong `scripts/`. LiveKit thêm ở giai đoạn 6.

## Chạy server cục bộ
```bash
docker compose -f dev/docker-compose.yml up -d
export CHAT_TOKEN_KEY=$(head -c 32 /dev/urandom | base64)   # khóa HMAC dev, >= 32 ký tự
export CHAT_DEV_OTP=1   # chưa có nhà cung cấp SMS/email: mã OTP được ghi vào log (CHỈ khi phát triển); thiếu biến này server không chạy
cd server && go run ./cmd/gateway     # :8080 — WebSocket /v1/connect, Connect RPC, /healthz
```
Dev/e2e thêm: `CHAT_DEV_OTP_CODE=123456` (mã OTP cố định, chỉ có tác dụng khi `CHAT_DEV_OTP=1`), `CHAT_CORS_ORIGINS=http://localhost:8140,...` (origin được gọi Connect từ trình duyệt; rỗng = tắt CORS).
Biến môi trường (có mặc định cho compose): `CHAT_POSTGRES_DSN`, `CHAT_DYNAMO_ENDPOINT`, `CHAT_DYNAMO_PREFIX`, `CHAT_NATS_URL`, `CHAT_LISTEN`, `CHAT_ENSURE_TABLES` (=1 tạo bảng DynamoDB nếu thiếu).

## Chạy test trên hạ tầng thật
```bash
export TEST_POSTGRES_DSN='postgres://chat:chat@localhost:5432/chat?sslmode=disable'
export TEST_DYNAMO_ENDPOINT=http://localhost:8000
cd server && go test -race -count=1 ./...
```
Mỗi test dùng schema Postgres và tiền tố bảng DynamoDB riêng. Không có hai biến này, test tương ứng được bỏ qua.
