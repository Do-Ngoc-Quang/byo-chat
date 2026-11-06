# Quy ước tổ chức repo

Nguồn duy nhất về chỗ đặt file. Đổi quy ước: sửa file này và thêm ADR trong `docs/decisions/`.

## Bố cục
```
README.md  CLAUDE.md  .gitignore
.github/workflows/   CI, mỗi phần một workflow lọc theo đường dẫn
docs/
  README.md          mục lục
  quy-uoc-to-chuc.md file này
  spec/              thiet-ke-chinh.md, giao-thuc.md, man-hinh.md
  decisions/         ADR: NNNN-ten-ngan.md
  notes.md           nhật ký phiên làm việc
  ui/                giao diện thiết kế (ngoại lệ, xem dưới)
proto/               buf.yaml, chat/v1/*.proto (nguồn sự thật của giao thức)
chatcore/            lõi Rust (workspace: crates/, wasm/, ffi/ khi có mã)
server/              Go (cmd/<dịch vụ>/, internal/, go.mod)
app/                 Flutter
infra/               Terraform, k8s/Argo CD
dev/                 docker-compose.yml, scripts/
poc/                 đóng băng, chỉ đọc
```

## Quy tắc
1. **Tên:** kebab-case cho file và thư mục (trừ quy ước của ngôn ngữ: `snake_case` Rust/Dart/proto, tên package Go). Tên tài liệu tiếng Việt không dấu; tên thư mục mã bằng tiếng Anh.
2. **Phiên bản tài liệu:** không đưa số phiên bản vào tên file. Ghi dòng `**Phiên bản:** x.y.z` ngay dưới tiêu đề. Quy tắc đánh số giữ như `CLAUDE.md`.
3. **Mã sinh từ proto:** không commit. Sinh khi build vào `gen/` trong từng phần (`chatcore/`, `server/`, `app/`), đã gitignore.
4. **Giao thức:** chỉ `proto/` và `docs/spec/giao-thuc.md` định nghĩa trường và luồng. Phần khác không tự định nghĩa lại.
5. **Quyết định:** quyết định kiến trúc vào `docs/decisions/` (ADR, không sửa sau khi chấp nhận). Việc dở và ghi chú phiên vào `docs/notes.md`.
6. **Mỗi thư mục cấp một** có `README.md` ngắn: mục đích, lệnh build/test, liên kết spec.
7. **`poc/`:** chỉ đọc. Khi nâng mã vào `chatcore/` hoặc `server/`, ghi nguồn gốc trong README của nơi nhận. Xóa `poc/` sau khi hoàn thành bước 1 của lộ trình (lịch sử git vẫn còn).
8. **Không commit:** `target/`, `node_modules/`, `build/`, `.dart_tool/`, `gen/`, `.env`, log, khóa/secret.
9. **CI:** workflow đặt tên theo phần (`proto.yml`, `chatcore.yml`, `server.yml`, `app.yml`), chạy lệnh ghi trong `CLAUDE.md`.
10. **Tạo thư mục mới** ở cấp một hoặc thêm loại file mới: cập nhật file này trước.

## Ngoại lệ: `docs/ui/`
Giữ phẳng, không chia thư mục con: `canvas.json` tham chiếu từng màn bằng tên file (`Main.dc.html` là màn danh sách chat mobile, `Mobile-*`, `Desktop-*`). Đổi tên hoặc di chuyển sẽ làm hỏng canvas. Chỉ đổi khi công cụ thiết kế cập nhật cùng lúc.
