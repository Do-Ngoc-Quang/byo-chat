package account_test

import (
	"encoding/hex"
	"testing"

	"byo-chat/server/internal/account"
)

// Vector sinh bởi chatcore (Rust), cùng nội dung với chatcore/crates/chatcore/tests/credential_vector.txt.
// Cả hai phía phải chấp nhận đúng credential này: giữ bố cục 136 byte và miền chữ ký đồng bộ.
const (
	vectorCred     = "1111111111111111111111111111111122222222222222222222222222222222d8fcd492b1b140ba3c80823e42a3c657ac765490198ed4438e4a40582a1ea3270000018bcfe56800a5edbd8a9853880d3409dee0e0c368c70c0ead72fe4955a38287deb2257e5005b448dc4af64c81f58e523c54cac10f918812a1476de206572a5ff362f3ca3601"
	vectorIdentity = "a64b1b730fe58553a021a4fa5b5f1b3e4427660371c9a02d4ac257ba7c4ea72a"
)

func TestCredentialVectorFromRust(t *testing.T) {
	cred, _ := hex.DecodeString(vectorCred)
	ident, _ := hex.DecodeString(vectorIdentity)
	c, err := account.ParseCredential(cred)
	if err != nil {
		t.Fatal(err)
	}
	if c.CreatedMs != 1_700_000_000_000 || c.Account[0] != 0x11 || c.Device[0] != 0x22 {
		t.Fatalf("%+v", c)
	}
	if !c.Verify(ident) {
		t.Fatal("server Go phải chấp nhận credential do chatcore (Rust) ký")
	}
	cred[10] ^= 1
	c, _ = account.ParseCredential(cred)
	if c.Verify(ident) {
		t.Fatal("sửa dữ liệu phải làm chữ ký hỏng")
	}
}
