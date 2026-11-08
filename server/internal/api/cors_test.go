package api_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"byo-chat/server/internal/api"
)

func TestCORS(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })
	h := api.CORS([]string{"http://localhost:5000/"}, next)

	// preflight từ origin được phép
	r := httptest.NewRequest(http.MethodOptions, "/chat.v1.AuthService/RequestOtp", nil)
	r.Header.Set("Origin", "http://localhost:5000")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusNoContent || w.Header().Get("Access-Control-Allow-Origin") != "http://localhost:5000" {
		t.Fatalf("%d %v", w.Code, w.Header())
	}
	for _, want := range []string{"Authorization", "Idempotency-Key", "Connect-Protocol-Version"} {
		if !contains(w.Header().Get("Access-Control-Allow-Headers"), want) {
			t.Fatalf("thiếu header %s: %q", want, w.Header().Get("Access-Control-Allow-Headers"))
		}
	}
	// origin lạ: không có header CORS, preflight đi tiếp tới handler (không được cho phép)
	r = httptest.NewRequest(http.MethodOptions, "/x", nil)
	r.Header.Set("Origin", "http://evil.example")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Header().Get("Access-Control-Allow-Origin") != "" || w.Code != http.StatusTeapot {
		t.Fatalf("origin lạ không được phép: %d %v", w.Code, w.Header())
	}
	// kho sao lưu dev: preflight đi tới handler của nó (không bị middleware chặn chỉ cho POST)
	r = httptest.NewRequest(http.MethodOptions, "/v1/dev-blob/backups/x", nil)
	r.Header.Set("Origin", "http://localhost:5000")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusTeapot || w.Header().Get("Access-Control-Allow-Methods") != "" {
		t.Fatalf("dev-blob phải đi qua middleware: %d %v", w.Code, w.Header())
	}
	// không cấu hình: nguyên handler
	if api.CORS(nil, next) == nil {
		t.Fatal("nil")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
