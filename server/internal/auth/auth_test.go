package auth

import (
	"strings"
	"testing"
	"time"

	"byo-chat/server/internal/ids"
)

func TestHMACRoundTripExpiryTamper(t *testing.T) {
	h, _ := NewHMAC([]byte(strings.Repeat("k", 32)))
	now := time.Unix(1_000_000, 0)
	c := Claims{Account: ids.New(), Device: ids.New(), Expires: now.Add(time.Hour)}
	tok := h.Issue(c)
	got, err := h.Verify(tok, now)
	if err != nil || got.Account != c.Account || got.Device != c.Device {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := h.Verify(tok, now.Add(2*time.Hour)); err != ErrExpired {
		t.Fatalf("muốn ErrExpired, nhận %v", err)
	}
	p, s, _ := strings.Cut(tok, ".")
	if _, err := h.Verify(p+"."+s[:len(s)-2]+"AA", now); err != ErrInvalid {
		t.Fatalf("chữ ký sai: %v", err)
	}
	other, _ := NewHMAC([]byte(strings.Repeat("z", 32)))
	if _, err := other.Verify(tok, now); err != ErrInvalid {
		t.Fatalf("khóa khác: %v", err)
	}
	if _, err := h.Verify("rác", now); err != ErrInvalid {
		t.Fatal(err)
	}
	if _, err := NewHMAC([]byte("ngắn")); err == nil {
		t.Fatal("khóa ngắn phải bị từ chối")
	}
}
