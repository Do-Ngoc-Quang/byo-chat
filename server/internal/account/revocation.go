package account

import (
	"crypto/ed25519"
	"encoding/binary"
	"errors"

	"byo-chat/server/internal/ids"
)

// RevocationLen: device_id(16) | revoked_ms(8, BE) | signature(64). Chữ ký Ed25519 của khóa danh tính tài khoản lên
// "chat.v1.revocation" ‖ 24 byte đầu (giao-thuc.md 6.6, làm rõ ở 1.2.1). Không chứa account_id: tài khoản suy ra từ
// khóa ký (mỗi tài khoản một khóa danh tính).
const RevocationLen = 88

const revDomain = "chat.v1.revocation"

var ErrRevocation = errors.New("account: revocation_statement sai bố cục")

type Revocation struct {
	Device    ids.ID
	RevokedMs uint64
	sig, body []byte
}

func ParseRevocation(b []byte) (Revocation, error) {
	if len(b) != RevocationLen {
		return Revocation{}, ErrRevocation
	}
	var r Revocation
	copy(r.Device[:], b[0:16])
	r.RevokedMs = binary.BigEndian.Uint64(b[16:24])
	r.body, r.sig = b[0:24], b[24:88]
	return r, nil
}

func (r Revocation) Verify(identity []byte) bool {
	if len(identity) != ed25519.PublicKeySize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(identity), append([]byte(revDomain), r.body...), r.sig)
}

// SignRevocation dựng statement (dùng cho test; client thật ký ở chatcore).
func SignRevocation(identity ed25519.PrivateKey, device ids.ID, revokedMs uint64) []byte {
	out := make([]byte, RevocationLen)
	copy(out[0:16], device[:])
	binary.BigEndian.PutUint64(out[16:24], revokedMs)
	copy(out[24:], ed25519.Sign(identity, append([]byte(revDomain), out[:24]...)))
	return out
}
