// Lệnh gateway: Gateway WebSocket + Connect RPC + Message Service trong một tiến trình (giai đoạn 2).
// Cấu hình qua biến môi trường (xem dev/README.md).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"byo-chat/server/internal/app"
	"byo-chat/server/internal/gateway"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
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
	a, err := app.New(ctx, app.Config{
		PostgresDSN:    env("CHAT_POSTGRES_DSN", "postgres://chat:chat@localhost:5432/chat?sslmode=disable"),
		DynamoEndpoint: env("CHAT_DYNAMO_ENDPOINT", "http://localhost:8000"),
		DynamoPrefix:   env("CHAT_DYNAMO_PREFIX", ""),
		NATSURL:        env("CHAT_NATS_URL", "nats://localhost:4222"),
		TokenKey:       []byte(key),
		EnsureTables:   env("CHAT_ENSURE_TABLES", "1") == "1",
		Gateway:        gateway.DefaultConfig(),
		Log:            log,
	})
	if err != nil {
		log.Error("khởi động", "err", err)
		os.Exit(1)
	}
	defer a.Close()

	srv := &http.Server{Addr: env("CHAT_LISTEN", ":8080"), Handler: a.Mux, ReadHeaderTimeout: 5 * time.Second}
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
