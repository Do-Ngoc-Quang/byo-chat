# 0007 — AuthService, RegisterDevice và KeyService ở server

- **Trạng thái:** Chấp nhận (07/11/2026)
- **Bối cảnh:** Lát cắt dọc cần đăng nhập OTP, đăng ký thiết bị và lấy KeyPackage. Spec 1.1.0 chưa định dạng credential và các tham số OTP/token; server chưa phân tích được MLS ở Go.
- **Quyết định:**
  - Spec 1.1.1 làm rõ: credential 136 byte bố cục cố định (không dùng Protobuf để tránh phụ thuộc mã hóa chuẩn tắc), tham số OTP, ticket, token.
  - Trạng thái OTP, ticket, refresh token nằm ở PostgreSQL (migration 0002), chỉ lưu băm; chưa dùng Valkey. Đăng ký thiết bị là một giao dịch: tiêu thụ ticket, so-và-đặt khóa danh tính, thêm thiết bị, KeyPackage, refresh token.
  - Interface `store.AccountStore` riêng (bộ nhớ và Postgres cùng chạy hợp đồng test), logic ở `internal/account`, handler Connect ở `internal/api`.
  - Gửi OTP qua interface `OTPSender`; chỉ có bản dev (ghi log, bật bằng `CHAT_DEV_OTP=1`). Chưa có nhà cung cấp SMS/email thật; passkey vẫn `Unimplemented`.
  - Server chưa phân tích KeyPackage MLS (kiểm định dạng ngoài: kích thước, số lượng); kiểm sâu làm cùng việc kiểm credential External Commit.
- **Hệ quả:** server tin client về nội dung KeyPackage, nên client phải kiểm credential và chữ ký khi `FetchKeyPackages` (đã là bước 2 của 6.2). `FetchKeyPackages` tiêu thụ gói một lần của người khác nên cần giới hạn tốc độ riêng sau này (kẻ xấu rút cạn gói về last resort). Chưa có RPC thay last resort (xoay 90 ngày).
