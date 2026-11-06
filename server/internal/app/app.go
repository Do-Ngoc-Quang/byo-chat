// Package app ghép các thành phần thành một tiến trình: kho (Postgres, DynamoDB), NATS/JetStream,
// Message Service, Gateway WebSocket và Connect RPC. Dùng chung cho cmd/gateway và test tích hợp.
package app

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/api"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/auth"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/gateway"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/message"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/natsx"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/dynamo"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/postgres"
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
	TokenKey       []byte // khóa HMAC dev; giai đoạn 3 thay bằng AuthService
	EnsureTables   bool   // tạo bảng DynamoDB nếu thiếu (dev/test)
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
	svc := message.New(postgres.New(pool), mb, q, natsx.NewBus(nc))
	svc.Log = cfg.Log
	gw := gateway.New(svc, tok, cfg.Gateway)
	gw.Log = cfg.Log
	mux := http.NewServeMux()
	mux.Handle("/v1/connect", gw)
	p, h := (&api.Conversation{Svc: svc, Verifier: tok}).Handler()
	mux.Handle(p, h)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	return &App{Svc: svc, Gateway: gw, Tokens: tok, Mux: mux, cfg: cfg, pool: pool, nc: nc}, nil
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
