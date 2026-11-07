# Quyết định kiến trúc (ADR)

Mỗi quyết định một file `NNNN-ten-ngan.md` (kebab-case, số tăng dần, không dùng lại). Không sửa ADR đã chấp nhận; muốn đổi thì viết ADR mới và đánh dấu ADR cũ là "Bị thay thế bởi NNNN".

Mẫu: Trạng thái · Bối cảnh · Quyết định · Hệ quả.

| # | Quyết định | Trạng thái |
|---|---|---|
| [0001](0001-to-chuc-repo.md) | Tổ chức repo | Chấp nhận |
| [0002](0002-tach-proto-chat-v1.md) | Cách tách file proto `chat.v1` | Chấp nhận |
| [0003](0003-xoa-poc.md) | Xóa `poc/` | Chấp nhận |
| [0004](0004-fanout-ben-server-toi-thieu.md) | Fanout bền, idempotency và giới hạn của server tối thiểu | Chấp nhận |
