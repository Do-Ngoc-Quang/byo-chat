// Package account: AuthService, RegisterDevice và KeyService (giao-thuc.md 6.1, ADR 0007).
package account

import (
	"crypto/ed25519"
	"encoding/binary"
	"errors"

	"byo-chat/server/internal/ids"
)

// CredentialLen là độ dài cố định của credential (giao-thuc.md 6.1):
// account_id(16) | device_id(16) | device_public_key(32) | created_ms(8, BE) | signature(64).
const (
	CredentialLen = 136
)

// credDomain là tiền tố miền của chữ ký, tránh dùng nhầm chữ ký cho việc khác.
const credDomain = "chat.v1.credential"

// Credential là credential đã tách trường.
type Credential struct {
	Account    ids.ID
	Device     ids.ID
	DevicePub  []byte // 32 byte Ed25519
	CreatedMs  uint64
	Signature  []byte // 64 byte
	signedBody []byte
}

var ErrCredential = errors.New("account: credential sai bố cục")

// ParseCredential tách credential; chưa kiểm chữ ký.
func ParseCredential(b []byte) (Credential, error) {
	if len(b) != CredentialLen {
		return Credential{}, ErrCredential
	}
	var c Credential
	copy(c.Account[:], b[0:16])
	copy(c.Device[:], b[16:32])
	c.DevicePub = b[32:64]
	c.CreatedMs = binary.BigEndian.Uint64(b[64:72])
	c.Signature = b[72:136]
	c.signedBody = b[0:72]
	return c, nil
}

// Verify kiểm chữ ký bằng khóa danh tính tài khoản (Ed25519, 32 byte).
func (c Credential) Verify(identity []byte) bool {
	if len(identity) != ed25519.PublicKeySize {
		return false
	}
	msg := append([]byte(credDomain), c.signedBody...)
	return ed25519.Verify(ed25519.PublicKey(identity), msg, c.Signature)
}

// SignCredential dựng credential (dùng cho test và công cụ dev; client thật dựng ở chatcore).
func SignCredential(identity ed25519.PrivateKey, account, device ids.ID, devicePub []byte, createdMs uint64) []byte {
	out := make([]byte, CredentialLen)
	copy(out[0:16], account[:])
	copy(out[16:32], device[:])
	copy(out[32:64], devicePub)
	binary.BigEndian.PutUint64(out[64:72], createdMs)
	copy(out[72:], ed25519.Sign(identity, append([]byte(credDomain), out[:72]...)))
	return out
}
