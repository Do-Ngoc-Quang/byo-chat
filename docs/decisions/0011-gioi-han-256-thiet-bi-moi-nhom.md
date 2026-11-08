# 0011 — Giới hạn 256 thiết bị mỗi nhóm

- **Trạng thái:** Chấp nhận (07/11/2026)
- **Bối cảnh:** Đo ở giai đoạn 4 (`chatcore/tests/sizes.rs`): Welcome và GroupInfo mang cả cây công khai nên tăng gần tuyến tính theo số thiết bị (51: 10 KB; 201: 38 KB; 256: 48 KB; 501: 94 KB; 1.000: 187 KB). Với giới hạn 1.000 thiết bị: (1) Welcome/GroupInfo vượt 128 KiB từ ~680 thiết bị; (2) `SubmitCommit` lặp cùng một Welcome cho từng thiết bị nhận, nên 50 phong bì vượt 3 MiB (và 4 MB của giao dịch DynamoDB) từ ~300 thiết bị. "Một Welcome cho nhiều người nhận" giải quyết (2) nhưng đổi proto và cách lưu hộp thư, tốn công cho nhu cầu chưa có.
- **Quyết định:** hạ giới hạn từ 1.000 xuống **256 thiết bị mỗi nhóm** (giữ 50 thiết bị mỗi Commit). Không đổi proto, không đổi giới hạn 128 KiB mỗi Commit/Welcome/GroupInfo, 3 MiB tổng Welcome mỗi Commit.
  - Ở 256: Welcome 48 KB, GroupInfo 48 KB, Commit 22 KB; 50 phong bì = 2,4 MB (77% ngân sách 3 MiB, dưới 4 MB giao dịch DynamoDB).
  - Đơn vị là thiết bị, không phải người: 256 thiết bị ~ 100-250 người tùy số thiết bị mỗi người.
  - Áp dụng ở lõi (`MAX_DEVICES_PER_GROUP`), server (`MaxGroupDevs`, `maxMembersCall`), spec mục 2, CLAUDE.md. Số đo hiệu năng mốc đổi theo (Commit cuối 22 KB, tạo 8 ms, nhận 2 ms ở Windows native).
  - Sửa lỗi lệch một khi kiểm giới hạn ở server: số thiết bị hiện có không tính thiết bị gửi Commit.
- **Hệ quả:** nhóm lớn hơn 256 thiết bị nằm ngoài phạm vi bản 1. Nếu sau này cần (kênh, cộng đồng), phải thiết kế lại: gửi một Welcome cho nhiều người nhận (trường proto mới), lưu Welcome một lần kèm con trỏ hộp thư, nâng giới hạn blob, và đo lại; đó là việc của một ADR mới. Tài liệu chính (thiet-ke-chinh.md) còn nhắc nhóm 1.000 thiết bị ở bảng PoC (mục 398); cần sửa khi cập nhật tài liệu chính.
