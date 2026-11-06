# byo-chat

Hệ thống chat mã hóa đầu cuối (E2EE, giao thức MLS) có gọi video. Máy chủ chỉ chuyển tiếp ciphertext.

> **Trạng thái:** giai đoạn khởi đầu. Đã chốt thiết kế và giao thức; PoC đã kiểm chứng các ca chính; `server/`, `app/`, `chatcore/` mới là khung (skeleton).

## Phạm vi
- Nền tảng: Android, Web, desktop. iOS để sau.
- Không làm: bot, kênh, stories, thanh toán, tìm kiếm phía server.

## Công nghệ
| Lớp | Công nghệ |
|---|---|
| Client | Flutter + lõi Rust `chatcore` (OpenMLS 0.8; WASM cho Web, FFI cho mobile/desktop) |
| Server | Go; WebSocket + Protobuf (`chat.v1`) + Connect RPC |
| Hạ tầng | NATS JetStream, Aurora PostgreSQL, DynamoDB, Valkey, Cloudflare R2 |
| Gọi video | LiveKit (SFrame) |
| MLS | `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` |

## Cấu trúc thư mục
| Thư mục | Nội dung |
|---|---|
| [`docs/`](docs/README.md) | Thiết kế chính, đặc tả giao thức, màn hình, giao diện, ADR |
| [`proto/`](proto) | Định nghĩa Protobuf `chat.v1` (kiểm tra bằng `buf`) |
| [`chatcore/`](chatcore) | Lõi Rust: MLS, mã hóa, xuất ra WASM/FFI |
| [`server/`](server) | Backend Go: gateway, Message Service, hộp thư |
| [`app/`](app) | Ứng dụng Flutter |
| [`infra/`](infra) | Terraform, k8s/Argo CD |
| [`dev/`](dev) | Môi trường dev cục bộ (docker-compose) |
| [`poc/`](poc) | Các bản thử nghiệm đã kiểm chứng thiết kế (đóng băng) |

## Kiểm tra mã
Các lệnh sẽ dùng được dần khi có mã:

```bash
# proto/
buf lint && buf breaking --against .git#branch=main

# chatcore/
cargo test --release
wasm-pack build --target web

# server/
go vet ./... && go test ./...

# app/
flutter analyze && flutter test
```

## Tài liệu
- [Thiết kế chính 1.3.0](docs/spec/thiet-ke-chinh.md) — kiến trúc, mô hình dữ liệu, lộ trình
- [Đặc tả giao thức 1.0.0](docs/spec/giao-thuc.md) — nguồn duy nhất cho Protobuf và luồng MLS
- [Màn hình 1.0.0](docs/spec/man-hinh.md) — 18 màn hình, điều hướng, trạng thái
- [Quy ước tổ chức repo](docs/quy-uoc-to-chuc.md)
- [Quyết định kiến trúc](docs/decisions/README.md)
- [Nhật ký phiên làm việc](docs/notes.md)

Hướng dẫn cho Claude Code nằm ở [`CLAUDE.md`](CLAUDE.md).
