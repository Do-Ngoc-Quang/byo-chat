package account

import (
	"context"
	"errors"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
)

// Liên kết thiết bị mới (giao-thuc.md 6.5).
const (
	LinkTTL         = 5 * time.Minute
	LinkWait        = 30 * time.Second
	linkPoll        = 300 * time.Millisecond
	x25519PublicLen = 32
	MaxSealedBundle = 1 << 10
)

// StartLink: thiết bị mới, chưa đăng nhập. link_id là bí mật 128 bit ngẫu nhiên (chỉ nằm trong mã QR).
// Chưa giới hạn tốc độ theo IP (việc dở: cần Valkey).
func (s *Service) StartLink(ctx context.Context, r *chatv1.StartLinkRequest) (*chatv1.StartLinkResponse, *message.Error) {
	inv := func(f string, a ...any) *message.Error {
		return perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, f, a...)
	}
	if len(r.DevicePublicKey) != ed25519PublicSize || len(r.EphemeralPublicKey) != x25519PublicLen {
		return nil, inv("device_public_key và ephemeral_public_key phải 32 byte")
	}
	if len(r.DeviceName) > MaxDeviceNameLen {
		return nil, inv("device_name quá dài")
	}
	id, _ := ids.FromBytes(randBytes(16))
	l := store.DeviceLink{
		ID: id, ShortCode: otpCode(), Platform: r.Platform, Name: r.DeviceName,
		DevicePub: r.DevicePublicKey, Ephemeral: r.EphemeralPublicKey, ExpiresAt: s.Now().Add(LinkTTL),
	}
	if err := s.Store.PutLink(ctx, l); err != nil {
		return nil, internal(s, "PutLink", err)
	}
	return &chatv1.StartLinkResponse{LinkId: id.Bytes(), ShortCode: l.ShortCode, ExpiresMs: uint64(l.ExpiresAt.UnixMilli())}, nil
}

// ApproveLink: thiết bị cũ đã tin cậy ký credential cho thiết bị mới. Server kiểm credential thuộc đúng tài khoản
// của người duyệt, đúng khóa thiết bị đã khai ở StartLink, và chữ ký đúng khóa danh tính đã lưu.
func (s *Service) ApproveLink(ctx context.Context, dev store.DeviceInfo, r *chatv1.ApproveLinkRequest) (*chatv1.ApproveLinkResponse, *message.Error) {
	inv := func(f string, a ...any) *message.Error {
		return perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, f, a...)
	}
	id, err := ids.FromBytes(r.LinkId)
	if err != nil {
		return nil, inv("link_id không hợp lệ")
	}
	if len(r.SealedBundle) == 0 || len(r.SealedBundle) > MaxSealedBundle {
		return nil, inv("sealed_bundle rỗng hoặc quá lớn")
	}
	now := s.Now()
	l, err := s.Store.GetLink(ctx, id, now)
	if errors.Is(err, store.ErrNotFound) {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "liên kết không tồn tại hoặc hết hạn")
	} else if err != nil {
		return nil, internal(s, "GetLink", err)
	}
	cred, err := ParseCredential(r.Credential)
	if err != nil {
		return nil, inv("credential sai bố cục")
	}
	if cred.Account != dev.AccountID || cred.Device.IsZero() || string(cred.DevicePub) != string(l.DevicePub) {
		return nil, inv("credential không khớp tài khoản người duyệt hoặc khóa thiết bị mới")
	}
	identity, err := s.Store.IdentityKey(ctx, dev.AccountID)
	if err != nil {
		return nil, internal(s, "IdentityKey", err)
	}
	if !cred.Verify(identity) {
		return nil, inv("chữ ký credential sai")
	}
	switch err := s.Store.ApproveLink(ctx, id, dev.AccountID, r.Credential, r.SealedBundle, now); {
	case errors.Is(err, store.ErrNotFound):
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "liên kết không tồn tại hoặc hết hạn")
	case errors.Is(err, store.ErrExists):
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS, "liên kết đã được duyệt")
	case err != nil:
		return nil, internal(s, "ApproveLink", err)
	}
	return &chatv1.ApproveLinkResponse{}, nil
}

// CompleteLink: thiết bị mới chờ tối đa 30 giây. Trả credential, sealed_bundle và session_ticket (dùng cho
// RegisterDevice không kèm khóa danh tính). Lấy xong liên kết bị xóa; mất phản hồi thì bắt đầu liên kết mới.
func (s *Service) CompleteLink(ctx context.Context, r *chatv1.CompleteLinkRequest) (*chatv1.CompleteLinkResponse, *message.Error) {
	id, err := ids.FromBytes(r.LinkId)
	if err != nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "link_id không hợp lệ")
	}
	deadline := s.Now().Add(LinkWait)
	for {
		now := s.Now()
		l, err := s.Store.TakeApprovedLink(ctx, id, now)
		if err == nil {
			ticket := randBytes(32)
			if err := s.Store.PutTicket(ctx, sha(ticket), l.Account, false, now.Add(TicketTTL)); err != nil {
				return nil, internal(s, "PutTicket", err)
			}
			return &chatv1.CompleteLinkResponse{Credential: l.Credential, SealedBundle: l.Sealed, SessionTicket: ticket}, nil
		}
		if !errors.Is(err, store.ErrNotFound) {
			return nil, internal(s, "TakeApprovedLink", err)
		}
		// Chưa duyệt, hay không có / hết hạn? Không có hoặc hết hạn thì báo ngay.
		if _, gerr := s.Store.GetLink(ctx, id, now); errors.Is(gerr, store.ErrNotFound) {
			return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "liên kết không tồn tại hoặc hết hạn")
		}
		if !now.Before(deadline) {
			return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa được duyệt, thử lại")
		}
		select {
		case <-ctx.Done():
			return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "đã hủy")
		case <-time.After(linkPoll):
		}
	}
}
