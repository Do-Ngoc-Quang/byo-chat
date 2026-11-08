# 0013 — Tên nhóm trong group context extension `chat_policy`

- **Trạng thái:** Chấp nhận (08/11/2026)
- **Bối cảnh:** Spec 6.2 bước 3 đặt tên nhóm trong `chat_policy` (group context extension) nhưng chưa định dạng. Hiện người nhận Welcome chỉ hiện "Nhóm" vì tên chỉ có ở máy người tạo.
- **Quyết định:** extension MLS loại `0xF001` (vùng riêng của ứng dụng) trong group context. Bản 1 chứa `version(1) = 1 ‖ tên nhóm UTF-8` (tối đa 100 byte); các trường khác của `chat_policy` (bảng vai trò, cờ External Commit, tự hủy) thêm sau bằng cách tăng `version`, người đọc bỏ qua phần không hiểu. Tên chỉ đặt lúc tạo nhóm; đổi tên bằng Commit `GroupContextExtensions` để sau.
  - Mọi KeyPackage khai báo hỗ trợ loại extension này trong `capabilities.extensions` (OpenMLS yêu cầu mọi thành viên hỗ trợ extension của group context). KeyPackage cũ (không khai báo) không thêm được vào nhóm có tên; dev chưa có dữ liệu thật nên không cần chuyển đổi.
  - Chi phí: vài byte mỗi KeyPackage và lá; không đổi proto, không đổi giới hạn.
- **Hệ quả:** người nhận Welcome và người vào bằng External Commit đọc tên từ GroupInfo/ratchet tree extension của chính nhóm, không cần server. Tên nhóm cũ chỉ ở máy người tạo thì giữ nguyên.
