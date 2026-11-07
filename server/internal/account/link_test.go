package account_test

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/account"
	"byo-chat/server/internal/store"
)

// TestLinkFlow: StartLink -> ApproveLink -> CompleteLink -> RegisterDevice không kèm khóa danh tính (giao-thuc.md 6.5).
func TestLinkFlow(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	old := newDev()
	if _, err := e.reg(acct, ticket, old, idKey, true); err != nil {
		t.Fatalf("thiết bị đầu: %v", err)
	}
	oldInfo := store.DeviceInfo{DeviceID: old.id, AccountID: acct}
	nu := newDev()
	eph := make([]byte, 32)

	start := func() *chatv1.StartLinkResponse {
		r, err := e.svc.StartLink(ctx, &chatv1.StartLinkRequest{DevicePublicKey: nu.pub, EphemeralPublicKey: eph})
		if err != nil {
			t.Fatalf("StartLink: %v", err.Msg)
		}
		return r
	}
	cred := account.SignCredential(idKey, acct, nu.id, nu.pub, uint64(e.now.UnixMilli()))

	// tham số sai
	if _, err := e.svc.StartLink(ctx, &chatv1.StartLinkRequest{DevicePublicKey: nu.pub[:5], EphemeralPublicKey: eph}); err == nil {
		t.Fatal("khóa thiết bị sai độ dài phải bị từ chối")
	}

	l := start()
	if len(l.ShortCode) != 6 || len(l.LinkId) != 16 {
		t.Fatalf("short_code/link_id sai: %q %d", l.ShortCode, len(l.LinkId))
	}

	// duyệt sai: credential cho khóa thiết bị khác, tài khoản khác, ký bằng khóa lạ
	other := newDev()
	_, strange, _ := ed25519.GenerateKey(nil)
	bad := map[string][]byte{
		"khóa thiết bị khác": account.SignCredential(idKey, acct, other.id, other.pub, 1),
		"khóa danh tính lạ":  account.SignCredential(strange, acct, nu.id, nu.pub, 1),
	}
	for name, c := range bad {
		if _, err := e.svc.ApproveLink(ctx, oldInfo, &chatv1.ApproveLinkRequest{LinkId: l.LinkId, Credential: c, SealedBundle: []byte("s")}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
			t.Fatalf("%s: muốn INVALID_ARGUMENT, nhận %v", name, err)
		}
	}
	stranger := store.DeviceInfo{DeviceID: other.id, AccountID: [16]byte{9}}
	if _, err := e.svc.ApproveLink(ctx, stranger, &chatv1.ApproveLinkRequest{LinkId: l.LinkId, Credential: cred, SealedBundle: []byte("s")}); err == nil {
		t.Fatal("tài khoản khác không được duyệt credential của tài khoản này")
	}

	// chưa duyệt: CompleteLink chờ rồi báo UNAVAILABLE (kéo đồng hồ giả để không phải đợi 30 giây thật)
	e.svc.Now = func() time.Time { e.now = e.now.Add(LinkWaitStep); return e.now }
	if _, err := e.svc.CompleteLink(ctx, &chatv1.CompleteLinkRequest{LinkId: l.LinkId}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE {
		t.Fatalf("chưa duyệt: muốn UNAVAILABLE, nhận %v", err)
	}
	e.svc.Now = func() time.Time { return e.now }

	// duyệt đúng; duyệt lần hai bị từ chối
	if _, err := e.svc.ApproveLink(ctx, oldInfo, &chatv1.ApproveLinkRequest{LinkId: l.LinkId, Credential: cred, SealedBundle: []byte("sealed")}); err != nil {
		t.Fatalf("ApproveLink: %v", err.Msg)
	}
	if _, err := e.svc.ApproveLink(ctx, oldInfo, &chatv1.ApproveLinkRequest{LinkId: l.LinkId, Credential: cred, SealedBundle: []byte("sealed")}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS {
		t.Fatalf("duyệt lần hai: muốn ALREADY_EXISTS, nhận %v", err)
	}

	done, err := e.svc.CompleteLink(ctx, &chatv1.CompleteLinkRequest{LinkId: l.LinkId})
	if err != nil {
		t.Fatalf("CompleteLink: %v", err.Msg)
	}
	if string(done.SealedBundle) != "sealed" || string(done.Credential) != string(cred) || len(done.SessionTicket) == 0 {
		t.Fatal("CompleteLink trả sai nội dung")
	}
	// lấy lần hai: liên kết đã bị xóa
	if _, err := e.svc.CompleteLink(ctx, &chatv1.CompleteLinkRequest{LinkId: l.LinkId}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("lấy lần hai: muốn NOT_FOUND, nhận %v", err)
	}

	// thiết bị mới đăng ký bằng ticket, KHÔNG gửi khóa danh tính
	r := &chatv1.RegisterDeviceRequest{
		SessionTicket: done.SessionTicket, DeviceId: nu.id.Bytes(), Platform: chatv1.Platform_PLATFORM_ANDROID,
		DevicePublicKey: nu.pub, Credential: done.Credential, KeyPackages: [][]byte{kp(), kp()}, LastResortKeyPackage: kp(),
	}
	if _, er := e.regReq(r); er != nil {
		t.Fatalf("RegisterDevice sau liên kết: %v", er)
	}

	// hết hạn
	l2 := start()
	e.now = e.now.Add(account.LinkTTL + time.Second)
	if _, err := e.svc.ApproveLink(ctx, oldInfo, &chatv1.ApproveLinkRequest{LinkId: l2.LinkId, Credential: cred, SealedBundle: []byte("s")}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("hết hạn: muốn NOT_FOUND, nhận %v", err)
	}
}

// LinkWaitStep là bước nhảy của đồng hồ giả mỗi lần CompleteLink đọc giờ: đủ lớn để vượt LinkWait sau vài vòng.
const LinkWaitStep = 10 * time.Second
