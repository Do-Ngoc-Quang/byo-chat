package account

import (
	"context"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
)

// MaxMediaBytes là kích thước tối đa một tệp media (khởi điểm; chốt theo chi phí S3 đo được, spec mục 11).
const MaxMediaBytes = 100 << 20

// Khóa đối tượng: media riêng (mã hóa đầu cuối) và ảnh đại diện công khai nằm ở hai tiền tố khác nhau.
// Không cần bảng riêng: tiền tố cho biết loại, lifecycle S3 xóa media riêng sau 30 ngày.
func mediaKey(id ids.ID, public bool) string {
	if public {
		return "media-public/" + id.Hex()
	}
	return "media/" + id.Hex()
}

// CreateUpload (MediaService): cấp URL tải lên cho một tệp đã mã hóa ở client (spec mục 11, bước 3).
func (s *Service) CreateUpload(ctx context.Context, _ store.DeviceInfo, r *chatv1.CreateUploadRequest) (*chatv1.CreateUploadResponse, *message.Error) {
	if s.Blobs == nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa cấu hình kho media")
	}
	if r.SizeBytes == 0 || r.SizeBytes > MaxMediaBytes {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "kích thước media phải trong (0, %d]", MaxMediaBytes)
	}
	if len(r.CiphertextSha256) != 32 {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "ciphertext_sha256 phải 32 byte")
	}
	id, _ := ids.FromBytes(randBytes(16))
	urls, part, err := s.Blobs.PresignPut(ctx, mediaKey(id, r.IsPublic), r.SizeBytes)
	if err != nil {
		return nil, internal(s, "PresignPut", err)
	}
	return &chatv1.CreateUploadResponse{MediaId: id.Bytes(), PartUrls: urls, PartSize: part,
		ExpiresMs: uint64(s.Now().Add(blobURLTTL).UnixMilli())}, nil
}

// blobURLTTL: thời hạn URL ký; khớp mặc định 15 phút của kho Dev và S3.
const blobURLTTL = 15 * time.Minute

// CompleteUpload: xác nhận đối tượng đã có trên kho. Tải một phần (hiện tại) không cần ghép; nhiều phần là việc hoãn.
func (s *Service) CompleteUpload(ctx context.Context, _ store.DeviceInfo, r *chatv1.CompleteUploadRequest) (*chatv1.CompleteUploadResponse, *message.Error) {
	if _, e := s.findMedia(ctx, r.MediaId); e != nil {
		return nil, e
	}
	return &chatv1.CompleteUploadResponse{}, nil
}

// GetDownloadUrl: URL ký có hạn ngắn. Media riêng chỉ là ciphertext, khóa nằm trong tin MLS nên mọi thiết bị đã đăng nhập
// được xin URL; media_id là UUIDv7 không đoán được. Ảnh đại diện công khai cùng cách (giao-thuc.md 6.15).
func (s *Service) GetDownloadUrl(ctx context.Context, _ store.DeviceInfo, r *chatv1.GetDownloadUrlRequest) (*chatv1.GetDownloadUrlResponse, *message.Error) {
	key, e := s.findMedia(ctx, r.MediaId)
	if e != nil {
		return nil, e
	}
	url, err := s.Blobs.PresignGet(ctx, key)
	if err != nil {
		return nil, internal(s, "PresignGet", err)
	}
	return &chatv1.GetDownloadUrlResponse{Url: url, ExpiresMs: uint64(s.Now().Add(blobURLTTL).UnixMilli())}, nil
}

func (s *Service) findMedia(ctx context.Context, raw []byte) (string, *message.Error) {
	if s.Blobs == nil {
		return "", perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa cấu hình kho media")
	}
	id, err := ids.FromBytes(raw)
	if err != nil {
		return "", perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "media_id phải 16 byte")
	}
	for _, pub := range []bool{false, true} {
		key := mediaKey(id, pub)
		ok, err := s.Blobs.Exists(ctx, key)
		if err != nil {
			return "", internal(s, "Exists", err)
		}
		if ok {
			return key, nil
		}
	}
	return "", perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "media không tồn tại hoặc chưa tải lên")
}
