package account_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/blob"
	"byo-chat/server/internal/store"
)

// TestMediaFlow: CreateUpload -> PUT -> CompleteUpload -> GetDownloadUrl -> GET; media riêng và công khai; lỗi biên.
func TestMediaFlow(t *testing.T) {
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

	for _, pub := range []bool{false, true} {
		data := []byte("tep da ma hoa")
		up, err := e.svc.CreateUpload(ctx, me, &chatv1.CreateUploadRequest{SizeBytes: uint64(len(data)), CiphertextSha256: sum, IsPublic: pub})
		if err != nil || len(up.PartUrls) != 1 || len(up.MediaId) != 16 || up.ExpiresMs == 0 {
			t.Fatalf("CreateUpload(pub=%v): %+v %v", pub, up, err)
		}
		// Chưa tải lên: Complete và GetDownloadUrl đều NOT_FOUND.
		if _, err := e.svc.CompleteUpload(ctx, me, &chatv1.CompleteUploadRequest{MediaId: up.MediaId}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
			t.Fatalf("chưa tải lên: muốn NOT_FOUND, nhận %v", err)
		}
		req, _ := http.NewRequest(http.MethodPut, up.PartUrls[0], bytes.NewReader(data))
		resp, er := http.DefaultClient.Do(req)
		if er != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("PUT: %v %v", er, resp)
		}
		resp.Body.Close()
		if _, err := e.svc.CompleteUpload(ctx, me, &chatv1.CompleteUploadRequest{MediaId: up.MediaId}); err != nil {
			t.Fatalf("CompleteUpload: %v", err)
		}
		dl, err := e.svc.GetDownloadUrl(ctx, me, &chatv1.GetDownloadUrlRequest{MediaId: up.MediaId})
		if err != nil || dl.Url == "" {
			t.Fatalf("GetDownloadUrl: %+v %v", dl, err)
		}
		g, er := http.Get(dl.Url)
		if er != nil {
			t.Fatal(er)
		}
		body, _ := io.ReadAll(g.Body)
		g.Body.Close()
		if !bytes.Equal(body, data) {
			t.Fatalf("tải xuống khác dữ liệu: %q", body)
		}
	}

	// Lỗi biên.
	bad := []struct {
		name string
		req  *chatv1.CreateUploadRequest
		code chatv1.ErrorCode
	}{
		{"0 byte", &chatv1.CreateUploadRequest{CiphertextSha256: sum}, chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE},
		{"quá lớn", &chatv1.CreateUploadRequest{SizeBytes: 100<<20 + 1, CiphertextSha256: sum}, chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE},
		{"hash sai độ dài", &chatv1.CreateUploadRequest{SizeBytes: 10, CiphertextSha256: sum[:5]}, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT},
	}
	for _, c := range bad {
		if _, err := e.svc.CreateUpload(ctx, me, c.req); err == nil || err.Code != c.code {
			t.Fatalf("%s: muốn %v, nhận %v", c.name, c.code, err)
		}
	}
	if _, err := e.svc.GetDownloadUrl(ctx, me, &chatv1.GetDownloadUrlRequest{MediaId: []byte("ngan")}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("media_id sai độ dài: %v", err)
	}
	if _, err := e.svc.GetDownloadUrl(ctx, me, &chatv1.GetDownloadUrlRequest{MediaId: make([]byte, 16)}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("không tồn tại: %v", err)
	}
	e.svc.Blobs = nil
	if _, err := e.svc.CreateUpload(ctx, me, &chatv1.CreateUploadRequest{SizeBytes: 1, CiphertextSha256: sum}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE {
		t.Fatalf("chưa cấu hình kho: %v", err)
	}
}
