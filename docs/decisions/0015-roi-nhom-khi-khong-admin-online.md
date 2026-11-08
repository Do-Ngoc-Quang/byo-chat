# 0015 — Rời nhóm khi không có admin online: server cho thành viên thường commit việc tự rời

- **Trạng thái:** Chấp nhận (08/11/2026). Làm rõ mục 6.4 của `docs/spec/giao-thuc.md` (1.3.2).
- **Bối cảnh:** Rời nhóm cần một Commit gỡ lá của người rời, mà MLS không cho tự gỡ chính mình. Hiện chỉ admin online commit được; nếu không ai là admin online thì người xin rời kẹt ở trạng thái "đang chờ". Spec 1.2.2 dự kiến cờ `chat_policy` cho thành viên thường commit, nhưng `chat_policy` là dữ liệu trong MLS, server không đọc được; còn quyền commit lại do server thi hành.
- **Quyết định:**
  - Không thêm cờ vào `chat_policy` (giữ `version = 1`, ADR 0013). Việc cho phép nằm ở server, nơi thi hành vai trò.
  - `SubmitProposal` đánh dấu `members_by_conv.leaving = true` cho tài khoản gửi (spec 6.4 bước 1 đã nói thế, cột `leaving` có từ migration 0001 nhưng chưa ai ghi). Mọi proposal hợp lệ của client đều là Remove tự gỡ (xem dưới) nên đánh dấu theo sự kiện là đúng.
  - `SubmitCommit` từ thành viên không phải admin được chấp nhận khi: có `removed_account_ids`, không có `added`/`role_changes`, và MỌI tài khoản bị gỡ đều đang `leaving` (và không phải OWNER, như cũ). Server không cần chờ 60 giây; thời gian chờ là phép lịch sự của client để admin làm trước và để ít tranh chấp epoch.
  - Client: admin commit sau độ trễ ngắn (như cũ); thành viên thường commit sau 60 giây cộng jitter nếu proposal vẫn còn chờ. Bên thua tranh chấp epoch (`EPOCH_MISMATCH`) bỏ qua.
  - Lõi `apply_proposal` chỉ nhận Remove mà người đề xuất là chính lá bị gỡ; proposal loại khác bị từ chối. Việc này đóng lỗ hổng sẵn có: một thành viên gửi Remove cho người khác, rồi lần commit-theo-proposal-chờ của admin sẽ gỡ nhầm người đó.
- **Hệ quả:**
  - Giới hạn chấp nhận: server không thấy nội dung Commit (PrivateMessage) nên không chặn được thành viên thường nhét thêm Remove cho người khác vào Commit "tự rời" của mình. Client hiện cũng chưa kiểm vai trò người commit (đúng cả với commit admin hiện nay). Kiểm vai trò người commit ở phía client là việc mở, ghi ở `docs/ke-hoach.md`.
  - Hẹn giờ commit dự phòng nằm trong bộ nhớ: tắt app giữa chừng thì hẹn lại khi nhận lại proposal chờ (chưa làm lại khi khởi động; người khác online vẫn commit được).
  - Người rời vẫn ở trạng thái đọc cho tới khi Commit tới (không đổi so với 1.2.2).
