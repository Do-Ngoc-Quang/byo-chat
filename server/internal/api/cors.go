package api

import (
	"net/http"
	"strings"
)

// CORS cho phép app Web (origin khác server) gọi Connect RPC. Chỉ các origin liệt kê mới được phép;
// danh sách rỗng thì không thêm header nào (mặc định an toàn). Không áp dụng cho WebSocket
// (kiểm Origin ở gateway nếu cần).
func CORS(origins []string, next http.Handler) http.Handler {
	if len(origins) == 0 {
		return next
	}
	allowed := map[string]bool{}
	for _, o := range origins {
		allowed[strings.TrimRight(strings.TrimSpace(o), "/")] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Kho sao lưu dev (blob.Dev) tự xử lý CORS cho URL ký của nó (PUT/GET), không dùng danh sách origin này.
		if strings.HasPrefix(r.URL.Path, "/v1/dev-blob/") {
			next.ServeHTTP(w, r)
			return
		}
		o := r.Header.Get("Origin")
		if o != "" && allowed[o] {
			h := w.Header()
			h.Add("Vary", "Origin")
			h.Set("Access-Control-Allow-Origin", o)
			h.Set("Access-Control-Expose-Headers", "Connect-Protocol-Version, Content-Type")
			if r.Method == http.MethodOptions {
				h.Set("Access-Control-Allow-Methods", "POST, OPTIONS")
				h.Set("Access-Control-Allow-Headers", "Content-Type, Connect-Protocol-Version, Connect-Timeout-Ms, Authorization, Idempotency-Key")
				h.Set("Access-Control-Max-Age", "600")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}
