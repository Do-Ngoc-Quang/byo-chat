package account_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/blob"
	"byo-chat/server/internal/store"
)

// TestBackupFlow: CreateBackupUpload -> PUT -> GetLatestBackup bằng session_ticket (khôi phục, giao-thuc.md 6.14) -> GET.
func TestBackupFlow(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	dev := blob.NewDev("", []byte("blob-secret-blob-secret-blob-secret"))
	dev.Now = func() time.Time { return e.now }
	mux := http.NewServeMux()
	p, h := dev.Handler()
	mux.Handle(p, h)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	dev.BaseURL = srv.URL
	e.svc.Blobs = dev

	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	a1 := newDev()
	if _, err := e.reg(acct, ticket, a1, idKey, true); err != nil {
		t.Fatal(err)
	}
	me := store.DeviceInfo{DeviceID: a1.id, AccountID: acct}
	sum := make([]byte, 32)

	// Chưa có bản sao lưu nào: NOT_FOUND. Đăng nhập lại (OTP) để có ticket khi mất thiết bị.
	e.now = e.now.Add(time.Minute) // qua khoảng chờ giữa hai lần xin OTP
	_, ticket2, _ := e.login(phone)
	if _, err := e.svc.GetLatestBackup(ctx, &chatv1.GetLatestBackupRequest{SessionTicket: ticket2}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("chưa có bản sao lưu: muốn NOT_FOUND, nhận %v", err)
	}
	if _, err := e.svc.GetLatestBackup(ctx, &chatv1.GetLatestBackupRequest{SessionTicket: []byte("gia")}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
		t.Fatalf("ticket giả: muốn UNAUTHENTICATED, nhận %v", err)
	}

	// Tham số sai.
	if _, err := e.svc.CreateBackupUpload(ctx, me, &chatv1.CreateBackupUploadRequest{SizeBytes: 0, CiphertextSha256: sum}); err == nil {
		t.Fatal("size 0 phải bị từ chối")
	}
	if _, err := e.svc.CreateBackupUpload(ctx, me, &chatv1.CreateBackupUploadRequest{SizeBytes: 10, CiphertextSha256: sum[:5]}); err == nil {
		t.Fatal("sha sai độ dài phải bị từ chối")
	}

	data := []byte("ban sao luu da ma hoa")
	up, err := e.svc.CreateBackupUpload(ctx, me, &chatv1.CreateBackupUploadRequest{SizeBytes: uint64(len(data)), CiphertextSha256: sum})
	if err != nil || len(up.PartUrls) != 1 {
		t.Fatalf("CreateBackupUpload: %+v %v", up, err)
	}
	// Đã cấp URL nhưng chưa tải lên: vẫn NOT_FOUND (không trả bản dở).
	if _, err := e.svc.GetLatestBackup(ctx, &chatv1.GetLatestBackupRequest{SessionTicket: ticket2}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("chưa tải lên: muốn NOT_FOUND, nhận %v", err)
	}
	// URL bị sửa chữ ký / vượt kích thước đã khai bị từ chối.
	put := func(url string, body []byte) int {
		req, _ := http.NewRequest(http.MethodPut, url, bytes.NewReader(body))
		resp, er := http.DefaultClient.Do(req)
		if er != nil {
			t.Fatal(er)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if c := put(strings.Replace(up.PartUrls[0], "sig=", "sig=00", 1), data); c != http.StatusForbidden {
		t.Fatalf("chữ ký sai: %d", c)
	}
	if c := put(up.PartUrls[0], append(data, 'x')); c != http.StatusRequestEntityTooLarge {
		t.Fatalf("vượt kích thước: %d", c)
	}
	if c := put(up.PartUrls[0], data); c != http.StatusOK {
		t.Fatalf("tải lên: %d", c)
	}

	got, err := e.svc.GetLatestBackup(ctx, &chatv1.GetLatestBackupRequest{SessionTicket: ticket2})
	if err != nil || got.SizeBytes != uint64(len(data)) || !bytes.Equal(got.BackupId, up.BackupId) {
		t.Fatalf("GetLatestBackup: %+v %v", got, err)
	}
	resp, er := http.Get(got.DownloadUrl)
	if er != nil {
		t.Fatal(er)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Equal(body, data) {
		t.Fatal("nội dung tải về khác nội dung đã tải lên")
	}
}
