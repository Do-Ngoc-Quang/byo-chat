# proto/chat/v1

Nguồn sự thật của trường Protobuf (`docs/spec/giao-thuc.md` mục 4 và 7.3). Đổi trường: sửa spec trước, ADR, rồi mới sửa ở đây.

- `common.proto`: enum, `Error`, `Member`, `CallKind`.
- `ws.proto`: khung WebSocket. `services.proto`: Connect RPC. `payload.proto`: plaintext bên trong MLS.
- Lệnh: `buf lint && buf format -d --exit-code && buf breaking --against .git#branch=main`
- Sinh mã: `buf generate` (cần `protoc-gen-go`, `protoc-gen-connect-go` trong PATH) ra `server/gen`, `app/lib/gen`; Rust dùng `chatcore/build.rs`.
- Số trường không bao giờ dùng lại; trường bỏ đi phải `reserved`. `buf.yaml` miễn hai luật tên response vì spec dùng chung response.
