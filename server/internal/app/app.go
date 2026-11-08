// Package app ghép các thành phần thành một tiến trình: kho (Postgres, DynamoDB), NATS/JetStream,
// Message Service, Gateway WebSocket và Connect RPC. Dùng chung cho cmd/gateway và test tích hợp.
package app

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"byo-chat/server/internal/account"
	"byo-chat/server/internal/api"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/blob"
	"byo-chat/server/internal/gateway"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/mlswire"
	"byo-chat/server/internal/natsx"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/dynamo"
	"byo-chat/server/internal/store/postgres"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
)

type Config struct {
	PostgresDSN    string
	DynamoEndpoint string // rỗng = AWS thật (cấu hình mặc định của SDK)
	DynamoPrefix   string
	DynamoRegion   string
	NATSURL        string
	TokenKey       []byte            // khóa HMAC ký access token; khóa băm liên hệ/OTP suy ra từ đây
	OTPSender      account.OTPSender // bắt buộc; dev dùng account.LogSender
	DevFixedOTP    string            // chỉ dev/e2e: mã OTP cố định
	DevBlobURL     string            // chỉ dev/e2e: URL công khai của chính server; bật kho sao lưu trong bộ nhớ (dùng S3 thì đặt S3)
	S3             *blob.S3Config    // kho sao lưu/media trên Amazon S3 (ADR 0014); nil = không có (hoặc DevBlobURL)
	S3Ensure       bool              // dev/test: tạo bucket và quy tắc lifecycle nếu thiếu
	EnsureTables   bool              // tạo bảng DynamoDB nếu thiếu (dev/test)
	RepairEvery    time.Duration
	Gateway        gateway.Config
	Log            *slog.Logger
}

type App struct {
	Svc     *message.Service
	Gateway *gateway.Server
	Tokens  *auth.HMAC
	Mux     *http.ServeMux
	cfg     Config
	pool    *pgxpool.Pool
	nc      *nats.Conn
}

// New kết nối hạ tầng, chạy migration và dựng handler. Chưa chạy worker: gọi Run.
func New(ctx context.Context, cfg Config) (*App, error) {
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	if cfg.DynamoRegion == "" {
		cfg.DynamoRegion = "us-east-1"
	}
	if cfg.RepairEvery == 0 {
		cfg.RepairEvery = 30 * time.Second
	}
	tok, err := auth.NewHMAC(cfg.TokenKey)
	if err != nil {
		return nil, err
	}
	pool, err := pgxpool.New(ctx, cfg.PostgresDSN)
	if err != nil {
		return nil, err
	}
	if err := postgres.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	opts := dynamodb.Options{Region: cfg.DynamoRegion}
	if cfg.DynamoEndpoint != "" {
		opts.BaseEndpoint = aws.String(cfg.DynamoEndpoint)
		opts.Credentials = credentials.NewStaticCredentialsProvider("local", "local", "")
	} else {
		pool.Close()
		return nil, errors.New("app: chưa hỗ trợ DynamoDB AWS thật (cần cấu hình credentials); đặt DynamoEndpoint")
	}
	mb := dynamo.New(dynamodb.New(opts), cfg.DynamoPrefix)
	if cfg.EnsureTables {
		if err := mb.EnsureTables(ctx); err != nil {
			pool.Close()
			return nil, err
		}
	}
	nc, err := nats.Connect(cfg.NATSURL, nats.Name("gateway"))
	if err != nil {
		pool.Close()
		return nil, err
	}
	q, err := natsx.NewQueue(ctx, nc)
	if err != nil {
		nc.Close()
		pool.Close()
		return nil, err
	}
	meta := postgres.New(pool)
	if cfg.OTPSender == nil {
		pool.Close()
		nc.Close()
		return nil, errors.New("app: thiếu OTPSender (dev: account.LogSender)")
	}
	acc := account.New(meta, meta, tok, cfg.OTPSender, contactKey(cfg.TokenKey))
	acc.Log = cfg.Log
	acc.DevFixedCode = cfg.DevFixedOTP
	if cfg.S3 != nil {
		s3, err := blob.NewS3(ctx, *cfg.S3)
		if err != nil {
			pool.Close()
			nc.Close()
			return nil, err
		}
		if cfg.S3Ensure {
			if err := s3.EnsureBucket(ctx); err != nil {
				pool.Close()
				nc.Close()
				return nil, fmt.Errorf("app: tạo bucket S3: %w", err)
			}
			if err := s3.EnsureLifecycle(ctx, "backups/", 365); err != nil {
				cfg.Log.Warn("không đặt được lifecycle S3 (đặt bằng hạ tầng khi chạy thật)", "err", err)
			}
		}
		acc.Blobs = s3
	}
	var devBlob *blob.Dev
	if cfg.DevBlobURL != "" && cfg.S3 == nil {
		devBlob = blob.NewDev(cfg.DevBlobURL, contactKey(append([]byte("blob:"), cfg.TokenKey...)))
		acc.Blobs = devBlob
	}
	svc := message.New(meta, mb, q, natsx.NewBus(nc))
	svc.Log = cfg.Log
	svc.CheckExternal = func(ctx context.Context, dev store.DeviceInfo, leaf mlswire.ExternalLeaf) error {
		return account.CheckExternalLeaf(ctx, meta, dev, leaf.Identity, leaf.SignatureKey)
	}
	gw := gateway.New(svc, tok, cfg.Gateway)
	gw.Log = cfg.Log
	acc.OnRevoke = gw.CloseDevice
	mux := http.NewServeMux()
	mux.Handle("/v1/connect", gw)
	p, h := (&api.Conversation{Svc: svc, Verifier: tok}).Handler()
	mux.Handle(p, h)
	for _, hf := range []func() (string, http.Handler){
		(&api.Auth{Svc: acc}).Handler,
		(&api.Device{Svc: acc, Verifier: tok}).Handler,
		(&api.Key{Svc: acc, Verifier: tok}).Handler,
		(&api.Profile{Svc: acc, Verifier: tok}).Handler,
		(&api.Backup{Svc: acc, Verifier: tok}).Handler,
	} {
		p, h := hf()
		mux.Handle(p, h)
	}
	if devBlob != nil {
		p, h := devBlob.Handler()
		mux.Handle(p, h)
	}
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	return &App{Svc: svc, Gateway: gw, Tokens: tok, Mux: mux, cfg: cfg, pool: pool, nc: nc}, nil
}

// contactKey suy ra khóa băm liên hệ/OTP từ khóa token (tách miền, không dùng chung khóa).
func contactKey(tokenKey []byte) []byte {
	m := hmac.New(sha256.New, tokenKey)
	m.Write([]byte("chat.v1.contact-key"))
	return m.Sum(nil)
}

// Run chạy worker fanout và vòng sửa chữa tới khi ctx hủy.
func (a *App) Run(ctx context.Context) error {
	errc := make(chan error, 1)
	go func() { errc <- a.Svc.Worker(ctx) }()
	go a.Svc.RepairLoop(ctx, a.cfg.RepairEvery)
	select {
	case <-ctx.Done():
		return nil
	case err := <-errc:
		return err
	}
}

// Close drain gateway rồi đóng kết nối hạ tầng.
func (a *App) Close() {
	a.Gateway.Drain()
	_ = a.nc.Drain()
	a.pool.Close()
}
