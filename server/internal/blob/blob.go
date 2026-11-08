// Package blob: kho đối tượng cho bản sao lưu đã mã hóa (spec BackupService, tài liệu chính mục 10).
// Sản phẩm dùng Amazon S3 qua URL ký sẵn (ADR 0014); S3 chưa có trong môi trường phát triển nên có `Dev`:
// lưu trong bộ nhớ và phục vụ PUT/GET qua HTTP với URL ký HMAC, cùng hình dạng như URL ký sẵn.
package blob

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Signer cấp URL tải lên/xuống có thời hạn. Cài đặt S3 thật: `NewS3`.
type Signer interface {
	// PresignPut trả các URL PUT theo từng phần (một phần với Dev) và kích thước mỗi phần.
	PresignPut(ctx context.Context, key string, size uint64) (urls []string, partSize uint32, err error)
	PresignGet(ctx context.Context, key string) (string, error)
	Exists(ctx context.Context, key string) (bool, error)
}

// Dev lưu đối tượng trong bộ nhớ. KHÔNG dùng ngoài phát triển/test.
type Dev struct {
	BaseURL string // ví dụ http://localhost:8080
	Secret  []byte
	TTL     time.Duration
	Now     func() time.Time
	MaxSize uint64

	mu   sync.Mutex
	objs map[string][]byte
	max  map[string]uint64 // kích thước tối đa đã cấp cho PUT
}

func NewDev(baseURL string, secret []byte) *Dev {
	return &Dev{BaseURL: strings.TrimRight(baseURL, "/"), Secret: secret, TTL: 15 * time.Minute, Now: time.Now, MaxSize: 256 << 20,
		objs: map[string][]byte{}, max: map[string]uint64{}}
}

const prefix = "/v1/dev-blob/"

func (d *Dev) sig(method, key string, exp int64) string {
	m := hmac.New(sha256.New, d.Secret)
	fmt.Fprintf(m, "%s\n%s\n%d", method, key, exp)
	return hex.EncodeToString(m.Sum(nil))
}

func (d *Dev) url(method, key string) string {
	exp := d.Now().Add(d.TTL).Unix()
	return fmt.Sprintf("%s%s%s?exp=%d&sig=%s", d.BaseURL, prefix, key, exp, d.sig(method, key, exp))
}

func (d *Dev) PresignPut(_ context.Context, key string, size uint64) ([]string, uint32, error) {
	if size == 0 || size > d.MaxSize {
		return nil, 0, fmt.Errorf("blob: kích thước %d ngoài (0, %d]", size, d.MaxSize)
	}
	d.mu.Lock()
	d.max[key] = size
	d.mu.Unlock()
	return []string{d.url(http.MethodPut, key)}, uint32(size), nil
}

func (d *Dev) PresignGet(_ context.Context, key string) (string, error) {
	return d.url(http.MethodGet, key), nil
}

func (d *Dev) Exists(_ context.Context, key string) (bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	_, ok := d.objs[key]
	return ok, nil
}

// Handler phục vụ PUT/GET cho URL của Dev; gắn vào mux tại "/v1/dev-blob/".
func (d *Dev) Handler() (string, http.Handler) {
	return prefix, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// App Web ở origin khác tải thẳng lên URL ký (như S3). URL đã ký nên cho mọi origin; chỉ bản Dev.
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, PUT, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		key := strings.TrimPrefix(r.URL.Path, prefix)
		exp, err := strconv.ParseInt(r.URL.Query().Get("exp"), 10, 64)
		if err != nil || d.Now().Unix() > exp || !hmac.Equal([]byte(r.URL.Query().Get("sig")), []byte(d.sig(r.Method, key, exp))) {
			http.Error(w, "url không hợp lệ hoặc hết hạn", http.StatusForbidden)
			return
		}
		switch r.Method {
		case http.MethodPut:
			d.mu.Lock()
			limit := d.max[key]
			d.mu.Unlock()
			b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, int64(limit)))
			if err != nil || limit == 0 {
				http.Error(w, "vượt kích thước đã khai", http.StatusRequestEntityTooLarge)
				return
			}
			d.mu.Lock()
			d.objs[key] = b
			d.mu.Unlock()
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			d.mu.Lock()
			b, ok := d.objs[key]
			d.mu.Unlock()
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(b)
		default:
			http.Error(w, "method", http.StatusMethodNotAllowed)
		}
	})
}
