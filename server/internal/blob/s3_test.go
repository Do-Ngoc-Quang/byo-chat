package blob

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

// Cần LocalStack S3 của dev/docker-compose.yml (localhost:4566); không có thì bỏ qua như các test hạ tầng khác.
func localS3(t *testing.T) *S3 {
	t.Helper()
	if c, err := net.DialTimeout("tcp", "localhost:4566", time.Second); err != nil {
		t.Skip("không có LocalStack S3 ở localhost:4566 (docker compose -f dev/docker-compose.yml up -d s3)")
	} else {
		c.Close()
	}
	ctx := context.Background()
	s, err := NewS3(ctx, S3Config{Bucket: "chat-blob-test", Endpoint: "http://localhost:4566", PathStyle: true, AccessKey: "test", SecretKey: "test", MaxSize: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureBucket(ctx); err != nil {
		t.Fatal(err)
	}
	return s
}

func do(t *testing.T, method, url string, body []byte) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(method, url, bytes.NewReader(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func TestS3PresignRoundTrip(t *testing.T) {
	s, ctx := localS3(t), context.Background()
	key := "backups/test/" + time.Now().Format("150405.000000")
	data := bytes.Repeat([]byte{7}, 4096)

	if ok, err := s.Exists(ctx, key); err != nil || ok {
		t.Fatalf("chưa tải lên thì không tồn tại: ok=%v err=%v", ok, err)
	}
	urls, part, err := s.PresignPut(ctx, key, uint64(len(data)))
	if err != nil || len(urls) != 1 || part != uint32(len(data)) {
		t.Fatalf("PresignPut: %v %v %d", urls, err, part)
	}
	// URL ký độ dài nội dung: tải lên sai độ dài bị từ chối.
	if code, _ := do(t, http.MethodPut, urls[0], data[:100]); code < 400 {
		t.Fatalf("độ dài sai phải bị từ chối, nhận %d", code)
	}
	if code, b := do(t, http.MethodPut, urls[0], data); code != http.StatusOK {
		t.Fatalf("PUT hợp lệ: %d %s", code, b)
	}
	if ok, err := s.Exists(ctx, key); err != nil || !ok {
		t.Fatalf("đã tải lên: ok=%v err=%v", ok, err)
	}
	get, err := s.PresignGet(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	if code, b := do(t, http.MethodGet, get, nil); code != http.StatusOK || !bytes.Equal(b, data) {
		t.Fatalf("GET: %d, %d byte", code, len(b))
	}
	// URL GET không dùng để PUT.
	if code, _ := do(t, http.MethodPut, get, data); code < 400 {
		t.Fatalf("URL GET không được ghi, nhận %d", code)
	}
	if _, _, err := s.PresignPut(ctx, key, 0); err == nil {
		t.Fatal("kích thước 0 phải bị từ chối")
	}
	if _, _, err := s.PresignPut(ctx, key, 2<<20); err == nil {
		t.Fatal("vượt MaxSize phải bị từ chối")
	}
	if err := s.EnsureLifecycle(ctx, "backups/", 30); err != nil {
		t.Fatalf("lifecycle: %v", err)
	}
}

func TestNewS3NeedsBucket(t *testing.T) {
	if _, err := NewS3(context.Background(), S3Config{}); err == nil {
		t.Fatal("thiếu bucket phải lỗi")
	}
}
