package account

import (
	"context"
	"errors"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
)

// ListDevices: mọi thiết bị của tài khoản người gọi, kể cả đã thu hồi.
func (s *Service) ListDevices(ctx context.Context, dev store.DeviceInfo) (*chatv1.ListDevicesResponse, *message.Error) {
	rows, err := s.Store.ListDevices(ctx, dev.AccountID)
	if err != nil {
		return nil, internal(s, "ListDevices", err)
	}
	out := &chatv1.ListDevicesResponse{}
	for _, r := range rows {
		out.Devices = append(out.Devices, &chatv1.DeviceInfo{
			DeviceId: r.DeviceID.Bytes(), Platform: r.Platform, DeviceName: r.Name,
			CreatedMs: r.CreatedMs, LastSeenMs: r.LastSeenMs, Revoked: r.Revoked,
		})
	}
	return out, nil
}

// RevokeDevice (giao-thuc.md 6.6 bước 2): kiểm statement ký đúng bởi khóa danh tính của tài khoản, rồi thu hồi trong
// một giao dịch (đánh dấu, xóa KeyPackage và refresh token, lưu statement). Không tự thu hồi chính mình (đăng xuất).
func (s *Service) RevokeDevice(ctx context.Context, dev store.DeviceInfo, r *chatv1.RevokeDeviceRequest) (*chatv1.RevokeDeviceResponse, *message.Error) {
	inv := func(f string, a ...any) *message.Error {
		return perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, f, a...)
	}
	target, err := ids.FromBytes(r.DeviceId)
	if err != nil || target.IsZero() {
		return nil, inv("device_id không hợp lệ")
	}
	if target == dev.DeviceID {
		return nil, inv("không tự thu hồi thiết bị đang dùng; hãy đăng xuất")
	}
	st, err := ParseRevocation(r.RevocationStatement)
	if err != nil || st.Device != target || st.RevokedMs == 0 {
		return nil, inv("revocation_statement sai bố cục hoặc không khớp device_id")
	}
	identity, err := s.Store.IdentityKey(ctx, dev.AccountID)
	if err != nil {
		return nil, internal(s, "IdentityKey", err)
	}
	if !st.Verify(identity) {
		return nil, inv("chữ ký revocation_statement sai")
	}
	switch err := s.Store.RevokeAccountDevice(ctx, dev.AccountID, target, r.RevocationStatement, s.Now()); {
	case errors.Is(err, store.ErrNotFound):
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "thiết bị không thuộc tài khoản này")
	case errors.Is(err, store.ErrExists):
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS, "thiết bị đã bị thu hồi")
	case err != nil:
		return nil, internal(s, "RevokeAccountDevice", err)
	}
	return &chatv1.RevokeDeviceResponse{}, nil
}
