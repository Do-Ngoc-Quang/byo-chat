# 0005 — Tên module Go không gắn host

- **Trạng thái:** Chấp nhận (07/11/2026)
- **Bối cảnh:** `server/go.mod` dùng `github.com/Do-Ngoc-Quang/byo-chat/server`, gắn cứng tên tài khoản GitHub vào mọi import và vào `go_package_prefix` của buf. `server` là chương trình chạy, không phải thư viện cho bên ngoài `go get`, nên đường dẫn module chỉ cần đúng nội bộ.
- **Quyết định:** đổi module thành `byo-chat/server` (không có tên miền). Sửa `server/go.mod`, mọi import trong `server/`, và `go_package_prefix` ở `proto/buf.gen.yaml`, `proto/buf.gen.server.yaml` thành `byo-chat/server/gen`. Mã sinh ra (`server/gen/`, bị `.gitignore`) sinh lại bằng `buf generate`.
- **Hệ quả:** đổi tên tài khoản/repo hoặc chuyển host không còn phải sửa import. Không `go get` được module từ ngoài; chấp nhận vì không có nhu cầu. Nếu sau này công khai module, đổi sang vanity path bằng ADR mới. Remote `origin` giữ nguyên.
