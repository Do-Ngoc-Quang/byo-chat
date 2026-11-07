# 0009 — Chat 1-1 ở client: kho cục bộ đi cùng snapshot MLS, quy tắc gửi/nhận

- **Trạng thái:** Chấp nhận (07/11/2026)
- **Bối cảnh:** Chat 1-1 cần nhận/giải mã tin, lưu lịch sử, Ack, gửi lại sau khi sập. Giải mã làm tiến ratchet MLS (không giải mã lại được cùng một tin), nên nếu trạng thái MLS và kho tin ghi lệch nhau sau khi sập thì mất tin hoặc dùng lại khóa.
- **Quyết định:**
  - Kho cục bộ (hội thoại, tin, con trỏ hộp thư, khóa danh tính đã thấy) là một tài liệu JSON do app dựng, giao cho chatcore giữ trong `app_state` của snapshot (op `app_state_set/get`; snapshot v2). Một lần ghi bền cho cả trạng thái MLS lẫn kho tin, nên chúng luôn khớp nhau. Ack chỉ gửi sau khi ghi xong.
  - Gửi tin: dựng ciphertext, GHI BỀN rồi mới gửi; ciphertext và epoch nằm cùng tin chờ gửi để gửi lại đúng bản đó (server khử trùng theo `client_msg_id`). Gặp `EPOCH_MISMATCH` thì đồng bộ `FetchLog` rồi dựng lại, tối đa 5 lần.
  - Nhận: áp dụng theo `seq` liên tục. Mục do chính thiết bị này ghi (tin, Commit) không được server gửi lại nên đánh dấu `skip`. Có khoảng trống thì gọi `FetchLog` NGAY (spec 3 nói giữ 5 giây: bỏ vì Deliver tới tuần tự theo hộp thư nên khoảng trống không tự lấp được).
  - Welcome đã có hội thoại thì bỏ qua (gửi lại sau sập); Welcome hỏng thì bỏ qua để không kẹt hộp thư; giải mã lỗi thì ghi chỗ giữ chỗ "không giải mã được" (7.2).
  - Nhóm MLS của người tạo dùng `group_id` làm khóa tạm, sau khi server cấp `conv_id` thì `rename_group`; `existed=true` thì `drop_group` (xóa cả khóa). Người nhận lấy khóa là `conv_id` của Welcome và biết người kia là ai từ credential trong cây nhóm (`group_members`).
  - Khóa danh tính người kia ghi lần đầu (TOFU); khác lần trước thì từ chối tạo hội thoại. Tra người bằng `LookupAccount` (server giới hạn 30 lần/giờ, spec 1.1.2). MLS đệm plaintext theo bội số 256 byte bằng `padding_size(256)` của OpenMLS.
  - Gateway chỉ nhận WebSocket khác origin từ các host liệt kê trong `CHAT_CORS_ORIGINS` (chống CSWSH); native không có Origin nên không ảnh hưởng.
- **Hệ quả:** mỗi thao tác ghi lại toàn bộ kho (O(kích thước)), chấp nhận cho 1-1 ở quy mô nhỏ; lịch sử dài/nhóm lớn cần chuyển sang kho có chỉ mục (SQLCipher/OPFS) giữ nguyên ý tưởng "một lần ghi nguyên tử với trạng thái MLS". Tin chỉ có văn bản; media, phản ứng, sửa/xóa, đã xem, typing làm sau. Chưa tự phục hồi khi giải mã lỗi liên tiếp (6.7), chưa xoay khóa định kỳ (6.8).
