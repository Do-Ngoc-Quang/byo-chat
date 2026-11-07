package account

import "encoding/base64"

// Refresh token ra ngoài dạng base64url của 32 byte ngẫu nhiên; server chỉ lưu SHA-256.
func encodeRefresh(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func decodeRefresh(s string) ([]byte, bool) {
	b, err := base64.RawURLEncoding.DecodeString(s)
	return b, err == nil && len(b) == 32
}
