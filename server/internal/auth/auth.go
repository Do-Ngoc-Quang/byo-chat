// Package auth: xác thực token truy cập. Giai đoạn 2 chỉ có token HMAC cho dev/test;
// OTP, passkey và cấp token thật làm ở giai đoạn 3 (AuthService) và thay Verifier này.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"byo-chat/server/internal/ids"
)

var (
	ErrInvalid = errors.New("auth: token không hợp lệ")
	ErrExpired = errors.New("auth: token hết hạn")
)

// Claims là nội dung token: tài khoản, thiết bị và hạn.
type Claims struct {
	Account ids.ID
	Device  ids.ID
	Expires time.Time
}

// Verifier kiểm tra token; Gateway và Connect dùng chung.
type Verifier interface {
	Verify(token string, now time.Time) (Claims, error)
}

// HMAC ký/kiểm token bằng HMAC-SHA256 (thư viện chuẩn, không tự viết primitive).
type HMAC struct{ key []byte }

func NewHMAC(key []byte) (*HMAC, error) {
	if len(key) < 32 {
		return nil, errors.New("auth: khóa HMAC tối thiểu 32 byte")
	}
	return &HMAC{key: key}, nil
}

type wire struct {
	A string `json:"a"`
	D string `json:"d"`
	E int64  `json:"e"`
}

func (h *HMAC) mac(p string) []byte {
	m := hmac.New(sha256.New, h.key)
	m.Write([]byte(p))
	return m.Sum(nil)
}

// Issue tạo token dạng base64url(payload).base64url(mac).
func (h *HMAC) Issue(c Claims) string {
	b, _ := json.Marshal(wire{c.Account.Hex(), c.Device.Hex(), c.Expires.Unix()})
	p := base64.RawURLEncoding.EncodeToString(b)
	return p + "." + base64.RawURLEncoding.EncodeToString(h.mac(p))
}

func (h *HMAC) Verify(token string, now time.Time) (Claims, error) {
	p, sig, ok := strings.Cut(token, ".")
	if !ok {
		return Claims{}, ErrInvalid
	}
	got, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil || !hmac.Equal(got, h.mac(p)) {
		return Claims{}, ErrInvalid
	}
	raw, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return Claims{}, ErrInvalid
	}
	var w wire
	if json.Unmarshal(raw, &w) != nil {
		return Claims{}, ErrInvalid
	}
	acct, e1 := parseHex(w.A)
	dev, e2 := parseHex(w.D)
	if e1 != nil || e2 != nil {
		return Claims{}, ErrInvalid
	}
	c := Claims{Account: acct, Device: dev, Expires: time.Unix(w.E, 0)}
	if !now.Before(c.Expires) {
		return c, ErrExpired
	}
	return c, nil
}

func parseHex(s string) (ids.ID, error) {
	var id ids.ID
	b, err := hex.DecodeString(s)
	if err != nil {
		return id, err
	}
	return ids.FromBytes(b)
}
