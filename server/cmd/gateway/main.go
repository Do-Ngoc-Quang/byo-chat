// Lệnh gateway: Gateway WebSocket + Connect RPC + Message Service trong một tiến trình (giai đoạn 2).
// Cấu hình qua biến môi trường (xem dev/README.md).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"byo-chat/server/internal/account"
	"byo-chat/server/internal/api"
	"byo-chat/server/internal/app"
	"byo-chat/server/internal/gateway"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// corsOrigins đọc CHAT_CORS_ORIGINS (danh sách phân tách bằng dấu phẩy); rỗng = không bật CORS.
func corsOrigins() []string {
	var out []string
	for _, o := range strings.Split(os.Getenv("CHAT_CORS_ORIGINS"), ",") {
		if o = strings.TrimSpace(o); o != "" {
			out = append(out, o)
		}
	}
	return out
}

// gwConfig: cấu hình gateway mặc định, thêm origin trình duyệt cho WebSocket từ CHAT_CORS_ORIGINS
// (cùng danh sách với CORS của Connect RPC).
func gwConfig() gateway.Config {
	c := gateway.DefaultConfig()
	for _, o := range corsOrigins() {
		if u, err := url.Parse(o); err == nil && u.Host != "" {
			c.OriginPatterns = append(c.OriginPatterns, u.Host)
		}
	}
	return c
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	key := os.Getenv("CHAT_TOKEN_KEY")
	if len(key) < 32 {
		log.Error("CHAT_TOKEN_KEY phải có ít nhất 32 ký tự (khóa HMAC dev)")
		os.Exit(2)
	}
	// Chưa có nhà cung cấp SMS/email (ADR 0007): chỉ chạy được khi bật rõ ràng chế độ dev.
	if os.Getenv("CHAT_DEV_OTP") != "1" {
		log.Error("chưa có nhà cung cấp OTP; đặt CHAT_DEV_OTP=1 để ghi mã OTP vào log (chỉ khi phát triển)")
		os.Exit(2)
	}
	a, err := app.New(ctx, app.Config{
		PostgresDSN:    env("CHAT_POSTGRES_DSN", "postgres://chat:chat@localhost:5432/chat?sslmode=disable"),
		DynamoEndpoint: env("CHAT_DYNAMO_ENDPOINT", "http://localhost:8000"),
		DynamoPrefix:   env("CHAT_DYNAMO_PREFIX", ""),
		NATSURL:        env("CHAT_NATS_URL", "nats://localhost:4222"),
		TokenKey:       []byte(key),
		OTPSender:      account.LogSender{Log: log},
		DevFixedOTP:    os.Getenv("CHAT_DEV_OTP_CODE"),
		EnsureTables:   env("CHAT_ENSURE_TABLES", "1") == "1",
		Gateway:        gwConfig(),
		Log:            log,
	})
	if err != nil {
		log.Error("khởi động", "err", err)
		os.Exit(1)
	}
	defer a.Close()

	srv := &http.Server{Addr: env("CHAT_LISTEN", ":8080"), Handler: api.CORS(corsOrigins(), a.Mux), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := a.Run(ctx); err != nil {
			log.Error("worker", "err", err)
			stop()
		}
	}()
	go func() {
		<-ctx.Done()
		a.Gateway.Drain() // 4009: client kết nối lại sau 0-30 giây
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	log.Info("gateway lắng nghe", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("http", "err", err)
		os.Exit(1)
	}
}
