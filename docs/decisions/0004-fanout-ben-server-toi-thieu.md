# 0004 — Fanout bền, idempotency và giới hạn của server tối thiểu

- **Trạng thái:** Chấp nhận (06/11/2026)
- **Bối cảnh:** giao-thuc.md 6.3 yêu cầu con trỏ hộp thư ghi "ngay sau giao dịch qua JetStream, idempotent theo `(conv_id, seq)`" và kiểm thử "sập giữa ghi Commit và con trỏ phải hoàn tất việc ghi con trỏ". Chỉ publish lên JetStream sau giao dịch thì sập đúng giữa hai bước làm mất job. Thành viên và GroupInfo nằm ở Postgres, log ở DynamoDB: không có giao dịch chung.
- **Quyết định:**
  1. Mọi việc sau giao dịch (con trỏ hộp thư, `members_by_conv`, `group_info`, báo Welcome) ghi thành `pending` ngay trong mục `conv_log`, cùng giao dịch với `conv_head`. JetStream chỉ là đường nhanh; `Service.Repair` quét mục còn `pending` và làm nốt. Mọi bước idempotent, xong thì xóa `pending`.
  2. `inbox_id` xác định theo `(server_ts_ms, conv, seq)` (ULID 16 byte có cấu trúc), nên ghi lại con trỏ nhiều lần ra cùng một khóa.
  3. `Idempotency-Key` của `SubmitCommit` ghi trong cùng giao dịch với Commit (bảng `idem`, TTL 24 giờ): gửi lại sau khi mất phản hồi nhận đúng kết quả cũ thay vì `EPOCH_MISMATCH`. `CreateConversation` idempotent theo `group_id` (Postgres UNIQUE).
  4. Cấp `seq` bằng giao dịch có điều kiện `head_seq = h AND epoch = e` (lạc quan, thử lại có jitter), không dùng bộ đếm riêng, để không bao giờ có lỗ trong `seq`.
  5. Phân quyền `SubmitCommit`: thêm/gỡ thành viên và đổi vai trò cần `ADMIN`/`OWNER`; Commit chỉ có path update (6.8) và gỡ thiết bị của chính tài khoản mình (6.6) thì mọi thành viên gửi được; External Commit không được mang thay đổi thành viên/vai trò.
  6. Giới hạn kích thước server áp thêm (chưa có trong spec): Commit 128 KiB, GroupInfo 128 KiB (để mục log kèm `pending` dưới 400 KB của DynamoDB), tổng Welcome mỗi Commit 3 MiB (giao dịch DynamoDB 4 MB). Chưa có số đo kích thước Welcome (điểm chưa kiểm của spec mục 8), cần đo ở giai đoạn 4.
- **Hệ quả:** thông lượng một hội thoại bị chặn bởi tranh chấp `head_seq` (đủ cho chat; đo lại khi tải lớn). `PendingFanouts` hiện dùng Scan; khi lớn cần GSI thưa. Tin nhắn phụ thuộc Postgres cho danh sách thiết bị của thành viên ở mỗi lần gửi (sau này cache Valkey).
