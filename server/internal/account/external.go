package account

import (
	"bytes"
	"context"
	"errors"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

// CheckExternalLeaf kiểm lá mới của External Commit (giao-thuc.md 6.5 bước 6): credential 136 byte phải thuộc đúng
// tài khoản và thiết bị đang gửi, khóa ký của lá phải là khóa công khai trong credential, và chữ ký credential phải
// đúng với khóa danh tính tài khoản mà server đã lưu. Chặn thành viên chèn lá mang danh tính người khác.
func CheckExternalLeaf(ctx context.Context, accts interface {
	IdentityKey(ctx context.Context, acct ids.ID) ([]byte, error)
}, dev store.DeviceInfo, identity, leafSigKey []byte) error {
	c, err := ParseCredential(identity)
	if err != nil {
		return err
	}
	if c.Account != dev.AccountID || c.Device != dev.DeviceID {
		return errors.New("credential của lá mới không thuộc thiết bị gửi")
	}
	if !bytes.Equal(c.DevicePub, leafSigKey) {
		return errors.New("khóa ký của lá mới không khớp credential")
	}
	key, err := accts.IdentityKey(ctx, c.Account)
	if err != nil || key == nil || !c.Verify(key) {
		return errors.New("chữ ký credential của lá mới sai")
	}
	return nil
}
