# 0010 — Liên kết thiết bị mới vào tài khoản đã có

- **Trạng thái:** Chấp nhận (07/11/2026)
- **Bối cảnh:** Spec 6.5 mô tả liên kết bằng "ECDH giữa khóa tạm của hai máy cùng một thuật toán mã hóa có xác thực" nhưng không chọn cấu trúc cụ thể. CLAUDE.md cấm tự viết primitive mật mã.
- **Quyết định:**
  - `sealed_bundle` là HPKE single-shot (RFC 9180, chế độ base) qua `OpenMlsCrypto::hpke_seal/hpke_open`, cùng bộ với cipher suite MLS (DHKEM X25519, HKDF-SHA256, AES-128-GCM). Thiết bị mới sinh cặp khóa HPKE từ 32 byte ngẫu nhiên (`derive_hpke_keypair`); khóa công khai là `ephemeral_public_key` (32 byte) của `StartLink`. `info` = `chat.v1.link`, `aad` = `link_id`, nên gói gắn với đúng một liên kết. Bản rõ là khóa danh tính tài khoản (TLS-serialize `SignatureKeyPair`, như `identity_export`). Dạng truyền: `pack([kem_output, ciphertext])`.
  - Thiết bị mới mở lõi ở trạng thái chờ (`open_device` với `account_id` rỗng), chưa có credential. `link_finish` mở gói, kiểm credential bằng khóa danh tính vừa nhận và khớp `device_id` + khóa ký của chính mình, rồi mới trở thành thiết bị đầy đủ. Credential cho thiết bị khác, gói của liên kết khác, hoặc máy khác mở gói đều bị từ chối.
  - Nội dung mã QR là `base64url(pack([link_id, device_id, device_public_key, ephemeral_public_key, short_code]))` (`LinkOffer`); `device_id` do thiết bị mới sinh trước khi `StartLink` để thiết bị cũ ký credential đúng ID.
  - Server không kiểm `short_code` (người dùng so khớp bằng mắt ở hai máy). `CompleteLink` long-poll tối đa 30 giây, lấy xong là xóa liên kết.
- **Hệ quả:** chưa chống lặp lại `StartLink` hàng loạt (cần giới hạn theo IP/Valkey). Khóa danh tính rời khỏi thiết bị gốc qua kênh gói HPKE; an toàn của nó dựa vào việc `link_id` (bí mật trong QR) chỉ tới đúng thiết bị mới và người dùng so khớp mã 6 số. Nếu mã QR bị chụp lại trước khi duyệt, kẻ tấn công có thể giành liên kết của mình với ephemeral key khác: vì vậy bước so khớp mã là bắt buộc ở giao diện.
