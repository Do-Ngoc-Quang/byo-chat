package call

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"
)

// Config: LiveKit (thiet-ke-chinh.md mục 12). Rỗng thì CallService trả UNAVAILABLE.
type Config struct {
	URL       string // wss://... của LiveKit
	APIKey    string
	APISecret string
	TokenTTL  time.Duration // mặc định 15 phút (token chỉ dùng để vào phòng)
	MaxCall   time.Duration // thời lượng tối đa một cuộc gọi, mặc định 4 giờ
}

func (c Config) ok() bool { return c.URL != "" && c.APIKey != "" && c.APISecret != "" }

// videoGrant theo định dạng access token của LiveKit.
type videoGrant struct {
	Room         string `json:"room"`
	RoomJoin     bool   `json:"roomJoin"`
	CanPublish   bool   `json:"canPublish"`
	CanSubscribe bool   `json:"canSubscribe"`
}

type claims struct {
	Iss   string     `json:"iss"`
	Sub   string     `json:"sub"`
	Nbf   int64      `json:"nbf"`
	Exp   int64      `json:"exp"`
	Video videoGrant `json:"video"`
}

// accessToken ký JWT HS256 cho LiveKit: định danh = device_id, phòng = call_id. Dùng HMAC-SHA256 của thư viện chuẩn.
func accessToken(c Config, room, identity string, now time.Time, ttl time.Duration) string {
	enc := base64.RawURLEncoding
	h := enc.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	p, _ := json.Marshal(claims{Iss: c.APIKey, Sub: identity, Nbf: now.Unix(), Exp: now.Add(ttl).Unix(),
		Video: videoGrant{Room: room, RoomJoin: true, CanPublish: true, CanSubscribe: true}})
	msg := h + "." + enc.EncodeToString(p)
	m := hmac.New(sha256.New, []byte(c.APISecret))
	m.Write([]byte(msg))
	return msg + "." + enc.EncodeToString(m.Sum(nil))
}
