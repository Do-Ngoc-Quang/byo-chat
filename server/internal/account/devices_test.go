package account_test

import (
	"context"
	"crypto/ed25519"
	"testing"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/account"
	"byo-chat/server/internal/store"
)

// TestListAndRevokeDevice: giao-thuc.md 6.6 bước 1-2 ở tầng dịch vụ.
func TestListAndRevokeDevice(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	a1 := newDev()
	if _, err := e.reg(acct, ticket, a1, idKey, true); err != nil {
		t.Fatalf("thiết bị đầu: %v", err)
	}
	// thiết bị thứ hai qua liên kết (không gửi khóa danh tính)
	a3 := newDev()
	l, _ := e.svc.StartLink(ctx, &chatv1.StartLinkRequest{DevicePublicKey: a3.pub, EphemeralPublicKey: make([]byte, 32)})
	me := store.DeviceInfo{DeviceID: a1.id, AccountID: acct}
	cred := account.SignCredential(idKey, acct, a3.id, a3.pub, 1)
	if _, err := e.svc.ApproveLink(ctx, me, &chatv1.ApproveLinkRequest{LinkId: l.LinkId, Credential: cred, SealedBundle: []byte("s")}); err != nil {
		t.Fatal(err.Msg)
	}
	done, _ := e.svc.CompleteLink(ctx, &chatv1.CompleteLinkRequest{LinkId: l.LinkId})
	if _, er := e.regReq(&chatv1.RegisterDeviceRequest{SessionTicket: done.SessionTicket, DeviceId: a3.id.Bytes(), DevicePublicKey: a3.pub,
		Credential: cred, KeyPackages: [][]byte{kp()}, LastResortKeyPackage: kp(), DeviceName: "máy ba"}); er != nil {
		t.Fatalf("đăng ký A3: %v", er)
	}

	list, err := e.svc.ListDevices(ctx, me)
	if err != nil || len(list.Devices) != 2 || list.Devices[1].DeviceName != "máy ba" || list.Devices[0].Revoked {
		t.Fatalf("ListDevices: %+v %v", list, err)
	}

	rev := func(dev store.DeviceInfo, target []byte, stmt []byte) *errT {
		_, er := e.svc.RevokeDevice(ctx, dev, &chatv1.RevokeDeviceRequest{DeviceId: target, RevocationStatement: stmt})
		if er != nil {
			return &errT{er.Code}
		}
		return nil
	}
	_, strange, _ := ed25519.GenerateKey(nil)
	wantCode(t, rev(me, a3.id.Bytes(), account.SignRevocation(strange, a3.id, 5)), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)           // ký bằng khóa lạ
	wantCode(t, rev(me, a3.id.Bytes(), account.SignRevocation(idKey, a1.id, 5)), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)             // statement của thiết bị khác
	wantCode(t, rev(me, a1.id.Bytes(), account.SignRevocation(idKey, a1.id, 5)), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)             // tự thu hồi
	wantCode(t, rev(me, newDev().id.Bytes(), account.SignRevocation(idKey, newDev().id, 5)), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT) // không khớp
	other := newDev()
	wantCode(t, rev(me, other.id.Bytes(), account.SignRevocation(idKey, other.id, 5)), chatv1.ErrorCode_ERROR_CODE_NOT_FOUND) // không thuộc tài khoản

	if er := rev(me, a3.id.Bytes(), account.SignRevocation(idKey, a3.id, 5)); er != nil {
		t.Fatalf("thu hồi đúng: %v", er)
	}
	wantCode(t, rev(me, a3.id.Bytes(), account.SignRevocation(idKey, a3.id, 5)), chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS)

	// Sau thu hồi: ListDevices báo revoked; thiết bị không còn trong thư mục khóa; statement được trả về; token làm mới bị chặn.
	list, _ = e.svc.ListDevices(ctx, me)
	if !list.Devices[1].Revoked {
		t.Fatal("A3 phải báo revoked")
	}
	keys, kerr := e.svc.FetchKeyPackages(ctx, &chatv1.FetchKeyPackagesRequest{AccountIds: [][]byte{acct.Bytes()}})
	if kerr != nil || len(keys.Accounts) != 1 || len(keys.Accounts[0].Devices) != 1 || len(keys.Accounts[0].RevocationStatements) != 1 {
		t.Fatalf("FetchKeyPackages sau thu hồi: %+v %v", keys, kerr)
	}
	if info, _ := e.meta.GetDevice(ctx, a3.id); !info.Revoked {
		t.Fatal("GetDevice phải báo Revoked (chặn access token)")
	}
}
