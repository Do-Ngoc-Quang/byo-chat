package account

import (
	"context"
	"crypto/ed25519"
	"testing"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

type fixedKey struct{ k []byte }

func (f fixedKey) IdentityKey(context.Context, ids.ID) ([]byte, error) { return f.k, nil }

func TestCheckExternalLeaf(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	acct, dev, other := ids.New(), ids.New(), ids.New()
	devPub := make([]byte, 32)
	devPub[0] = 1
	cred := SignCredential(priv, acct, dev, devPub, 5)
	me := store.DeviceInfo{AccountID: acct, DeviceID: dev}
	ctx := context.Background()
	if err := CheckExternalLeaf(ctx, fixedKey{pub}, me, cred, devPub); err != nil {
		t.Fatalf("hợp lệ phải qua: %v", err)
	}
	_, evil, _ := ed25519.GenerateKey(nil)
	for name, c := range map[string]struct {
		dev  store.DeviceInfo
		cred []byte
		sig  []byte
	}{
		"thiết bị khác":   {store.DeviceInfo{AccountID: acct, DeviceID: other}, cred, devPub},
		"tài khoản khác":  {store.DeviceInfo{AccountID: other, DeviceID: dev}, cred, devPub},
		"khóa ký lệch":    {me, cred, make([]byte, 32)},
		"ký bằng khóa lạ": {me, SignCredential(evil, acct, dev, devPub, 5), devPub},
		"sai độ dài":      {me, cred[:100], devPub},
	} {
		if err := CheckExternalLeaf(ctx, fixedKey{pub}, c.dev, c.cred, c.sig); err == nil {
			t.Errorf("%s: phải bị từ chối", name)
		}
	}
}
