# 0014 — Dùng Amazon S3 thay Cloudflare R2 cho kho đối tượng

- **Trạng thái:** Chấp nhận (08/11/2026). Thay quyết định số 9 của tài liệu chính (R2 cho media).
- **Bối cảnh:** R2 được chọn vì không tính phí egress. Mọi dịch vụ còn lại (Aurora, DynamoDB, NLB, KMS, Secrets Manager) đã nằm trên AWS, nên R2 buộc thêm một nhà cung cấp, một tài khoản và khóa API dài hạn chỉ để cất blob. Phần việc "R2 thật" của giai đoạn 4 đang chờ tài khoản đó. R2 và S3 cùng dùng URL ký sẵn theo kiểu S3, nên đổi không chạm giao thức.
- **Quyết định:**
  - Kho đối tượng (bản sao lưu giai đoạn 4, media giai đoạn 5) dùng **Amazon S3**: URL ký sẵn SigV4, tải nhiều phần, lifecycle (xóa sau 30 ngày với media, cùng TTL ciphertext), SSE-KMS.
  - Server xác thực bằng IAM role, không có khóa dài hạn. Bucket chặn truy cập công khai, trừ tiền tố ảnh đại diện công khai (ngoại lệ duy nhất của quy tắc "server chỉ chuyển ciphertext").
  - Giữ interface `blob.Signer` (`PresignPut`/`PresignGet`/`Exists`); thêm cài đặt `blob.S3` dùng `aws-sdk-go-v2/service/s3`. `blob.Dev` giữ cho e2e không cần S3. Dev cục bộ dùng LocalStack S3 (compose, cổng 4566) qua `CHAT_S3_ENDPOINT`; MinIO không dùng được vì không còn ảnh Docker chính thức tải được (08/11/2026).
  - Cloudflare vẫn dùng cho DNS, WAF, DDoS, Turnstile; chỉ phần lưu trữ đổi.
  - CDN: ban đầu S3 phục vụ trực tiếp bằng URL ký có hạn ngắn; CloudFront đặt trước S3 khi egress đáng kể hoặc cho ảnh đại diện công khai (việc sau, không chặn).
- **Hệ quả:**
  - Mất lợi thế không phí egress của R2. Chi phí media tăng theo lượt tải; theo dõi từ giai đoạn 5, CloudFront (có giá egress thấp hơn S3 trực tiếp) là bước giảm đầu tiên. Nếu chi phí không chấp nhận được, quay lại R2 chỉ cần một cài đặt `Signer` khác (interface giữ nguyên).
  - Bỏ việc chờ tài khoản R2; thay bằng cấu hình bucket, IAM, lifecycle, CORS (đặt trong hạ tầng, không nằm trong repo này).
  - Sửa: `CLAUDE.md`, `README.md`, `thiet-ke-chinh.md` (1.4.0: bảng công nghệ, mục media, mô hình dữ liệu, bảo mật, bảng quyết định), `docs/ke-hoach.md`.
