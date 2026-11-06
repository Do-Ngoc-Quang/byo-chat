# Quy ước tổ chức repo

Nguồn duy nhất về chỗ đặt file. Đổi quy ước: sửa file này và thêm ADR trong `docs/decisions/`.

## Bố cục
```
README.md  CLAUDE.md  .gitignore
.github/workflows/   CI, mỗi phần một workflow lọc theo đường dẫn
docs/
  README.md          mục lục
  quy-uoc-to-chuc.md file này
  ke-hoach.md        kế hoạch, checklist, tiến độ (nơi duy nhất)
  spec/              thiet-ke-chinh.md, giao-thuc.md, man-hinh.md
  decisions/         ADR: NNNN-ten-ngan.md
  notes.md           nhật ký phiên làm việc
  ui/                giao diện thiết kế (ngoại lệ, xem dưới)
proto/               buf.yaml, buf.gen*.yaml, chat/v1/*.proto (nguồn sự thật của giao thức)
chatcore/            lõi Rust (workspace: crates/, wasm/, ffi/ khi có mã)
server/              Go (cmd/<dịch vụ>/, internal/, go.mod); migration SQL nằm trong internal/store/postgres/migrations/ (go:embed)
app/                 Flutter
infra/               Terraform, k8s/Argo CD
dev/                 docker-compose.yml, scripts/
```

## Quy tắc
1. **Tên:** kebab-case cho file và thư mục (trừ quy ước của ngôn ngữ: `snake_case` Rust/Dart/proto, tên package Go). Tên tài liệu tiếng Việt không dấu; tên thư mục mã bằng tiếng Anh.
2. **Phiên bản tài liệu:** không đưa số phiên bản vào tên file. Ghi dòng `**Phiên bản:** x.y.z` ngay dưới tiêu đề. Quy tắc đánh số giữ như `CLAUDE.md`.
3. **Mã sinh từ proto:** không commit. Sinh khi build vào `gen/` trong từng phần (`chatcore/`, `server/`, `app/`), đã gitignore. `proto/buf.gen.yaml` sinh đủ Go+Dart; `proto/buf.gen.server.yaml` chỉ Go+Connect (không cần plugin remote) cho `server/` và CI `server.yml`.
4. **Giao thức:** chỉ `proto/` và `docs/spec/giao-thuc.md` định nghĩa trường và luồng. Phần khác không tự định nghĩa lại.
5. **Quyết định và tiến độ:** quyết định kiến trúc vào `docs/decisions/` (ADR, không sửa sau khi chấp nhận). Tiến độ và việc cần làm chỉ ở `docs/ke-hoach.md`. Ghi chú phiên vào `docs/notes.md`.
6. **Mỗi thư mục cấp một** có `README.md` ngắn: mục đích, lệnh build/test, liên kết spec.
7. **`poc/`:** đã xóa (ADR 0003). Kết quả PoC nằm ở `docs/spec/giao-thuc.md` mục 8.
8. **Không commit:** `target/`, `node_modules/`, `build/`, `.dart_tool/`, `gen/`, `.env`, log, khóa/secret.
9. **CI:** workflow đặt tên theo phần (`proto.yml`, `chatcore.yml`, `server.yml`, `app.yml`), chạy lệnh ghi trong `CLAUDE.md`.
10. **Git:** xem mục "Quy trình git" bên dưới.
11. **Tạo thư mục mới** ở cấp một hoặc thêm loại file mới: cập nhật file này trước.

## Quy trình git
- `main` luôn ở trạng thái dùng được; không push trực tiếp.
- Mọi thay đổi đi qua nhánh rồi PR vào `main`. Mỗi PR một mục tiêu nhỏ (khớp mục tiêu phiên làm việc).
- Tên nhánh: `loai/ten-ngan`, kebab-case; loại là `feat`, `fix`, `docs`, `chore`, `refactor`, `test`. Ví dụ `feat/proto-common`, `docs/ke-hoach`. Phiên cloud của Claude có thể dùng nhánh do hệ thống cấp (`claude/...`).
- Thông điệp commit: dòng đầu ngắn, mệnh lệnh, tiếng Anh hoặc tiếng Việt thống nhất trong một PR; phần thân nêu lý do.
- PR phải: CI xanh (khi đã có), cập nhật `docs/ke-hoach.md` nếu hoàn thành đầu việc, thêm ADR nếu đổi kiến trúc hoặc quy ước.
- `main` là nhánh mặc định. GitHub tự xóa nhánh sau khi merge; nhánh tiếp theo tách từ `main` mới nhất.

## Ngoại lệ: `docs/ui/`
Giữ phẳng, không chia thư mục con: `canvas.json` tham chiếu từng màn bằng tên file (`Main.dc.html` là màn danh sách chat mobile, `Mobile-*`, `Desktop-*`). Đổi tên hoặc di chuyển sẽ làm hỏng canvas. Chỉ đổi khi công cụ thiết kế cập nhật cùng lúc.
