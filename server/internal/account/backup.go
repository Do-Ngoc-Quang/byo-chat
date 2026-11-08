package account

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/blob"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
)

// MaxBackupBytes là kích thước tối đa một bản sao lưu (khởi điểm; chốt theo chi phí S3 đo được).
const MaxBackupBytes = 256 << 20

// CreateBackupUpload (BackupService): cấp URL tải lên. Bản ghi được tạo ngay; GetLatestBackup chỉ trả bản đã có đối tượng.
func (s *Service) CreateBackupUpload(ctx context.Context, dev store.DeviceInfo, r *chatv1.CreateBackupUploadRequest) (*chatv1.CreateBackupUploadResponse, *message.Error) {
	inv := func(f string, a ...any) *message.Error {
		return perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, f, a...)
	}
	if s.Blobs == nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa cấu hình kho sao lưu")
	}
	if r.SizeBytes == 0 || r.SizeBytes > MaxBackupBytes {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "kích thước sao lưu phải trong (0, %d]", MaxBackupBytes)
	}
	if len(r.CiphertextSha256) != 32 {
		return nil, inv("ciphertext_sha256 phải 32 byte")
	}
	id, _ := ids.FromBytes(randBytes(16))
	key := fmt.Sprintf("backups/%s/%s", dev.AccountID.Hex(), id.Hex())
	urls, part, err := s.Blobs.PresignPut(ctx, key, r.SizeBytes)
	if err != nil {
		return nil, internal(s, "PresignPut", err)
	}
	if err := s.Store.PutBackup(ctx, dev.AccountID, key, r.SizeBytes, s.Now()); err != nil {
		return nil, internal(s, "PutBackup", err)
	}
	return &chatv1.CreateBackupUploadResponse{BackupId: id.Bytes(), PartUrls: urls, PartSize: part}, nil
}

// GetLatestBackup: dùng khi chưa có thiết bị (giao-thuc.md 6.14), xác thực bằng session_ticket (không tiêu thụ).
func (s *Service) GetLatestBackup(ctx context.Context, r *chatv1.GetLatestBackupRequest) (*chatv1.GetLatestBackupResponse, *message.Error) {
	if s.Blobs == nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa cấu hình kho sao lưu")
	}
	acct, _, err := s.Store.TicketAccount(ctx, sha(r.SessionTicket), s.Now())
	if errors.Is(err, store.ErrTicketInvalid) {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "session_ticket không hợp lệ hoặc hết hạn")
	} else if err != nil {
		return nil, internal(s, "TicketAccount", err)
	}
	return s.latest(ctx, acct)
}

func (s *Service) latest(ctx context.Context, acct ids.ID) (*chatv1.GetLatestBackupResponse, *message.Error) {
	rows, err := s.Store.Backups(ctx, acct, 5)
	if err != nil {
		return nil, internal(s, "Backups", err)
	}
	for _, b := range rows { // bản mới nhất mà đối tượng đã được tải lên đủ
		ok, err := s.Blobs.Exists(ctx, b.ObjectKey)
		if err != nil {
			return nil, internal(s, "Exists", err)
		}
		if !ok {
			continue
		}
		url, err := s.Blobs.PresignGet(ctx, b.ObjectKey)
		if err != nil {
			return nil, internal(s, "PresignGet", err)
		}
		id, _ := ids.FromBytes(backupIDFromKey(b.ObjectKey))
		return &chatv1.GetLatestBackupResponse{BackupId: id.Bytes(), DownloadUrl: url, SizeBytes: b.Size, CreatedMs: b.CreatedMs}, nil
	}
	return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "chưa có bản sao lưu")
}

// backupIDFromKey lấy 16 byte cuối (hex) của khóa đối tượng.
func backupIDFromKey(key string) []byte {
	if n := len(key); n >= 32 {
		if b, err := hex.DecodeString(key[n-32:]); err == nil {
			return b
		}
	}
	return make([]byte, 16)
}

var _ blob.Signer = (*blob.Dev)(nil)
